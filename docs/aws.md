# Running the package on AWS EC2

How an API image built on this package runs on EC2: two instances behind an ALB, in an Auto
Scaling group rolled with instance refresh. **Nothing in this repository creates AWS
resources, and none of the commands below have been run.** The commands show the intended
shape. The behaviour described comes from reading the pinned sources:
[ops 0.1.47](https://github.com/nanovms/ops/tree/fc3195f46c54ad94a0bcce69373d67a4441e0955) and
[nanos 0.1.56](https://github.com/nanovms/nanos/tree/aad473aad2f73a9893d5c32be333f2796725ab82).
The open questions at the end need a test in a staging account before production relies on them.

Links below use `ops@0.1.47:path:line` and `nanos@0.1.56:path:line`.

## Architecture: x86_64 and Graviton

`ops image create -t aws` builds AMIs for both architectures. Two separate inputs set the
architecture, and they must agree:

- `--arch arm64` selects the arm64 kernel (`~/.ops/<nanos>-arm`), its klibs and the arm64
  local package.
- `CloudConfig.Flavor` alone sets the AMI's `Architecture` (and UEFI for arm64). ops looks
  up the instance family in a fixed table
  ([ops@0.1.47:provider/aws/aws_image.go:73](https://github.com/nanovms/ops/blob/fc3195f46c54ad94a0bcce69373d67a4441e0955/provider/aws/aws_image.go#L73),
  [:416-514](https://github.com/nanovms/ops/blob/fc3195f46c54ad94a0bcce69373d67a4441e0955/provider/aws/aws_image.go#L416-L514)).
  A family missing from the table registers as `x86_64`.

The table knows Graviton 2 and 3 families (`t4g`, `m6g`, `c6g`, `r6g`, `m7g`, `c7g`, `r7g`
and their `d`/`n` variants). It does not know Graviton 4 (`m8g`, `c8g`, `r8g`). Building with
`Flavor: "m8g.large"` therefore registers an x86_64 AMI around an arm64 kernel, and that AMI
does not boot. Build arm64 AMIs with a listed family such as `m7g.large`. An AMI is not bound
to an instance type, so the launch template can still name another family; whether Nanos
runs on Graviton 4 is unverified.

`RegisterImage` sets `EnaSupport: true`, a gp2 root volume and no `BootMode`
([:142-160](https://github.com/nanovms/ops/blob/fc3195f46c54ad94a0bcce69373d67a4441e0955/provider/aws/aws_image.go#L142-L160)).
Without a `BootMode`, EC2 boots Graviton with UEFI and x86 with legacy BIOS
([AWS: boot modes](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ami-boot-mode.html)).
Nanos' arm64 (`virt`) platform includes the ENA, NVMe and ACPI drivers that Nitro needs. The
ops documentation lists Graviton 2 and 3, and x86 Nitro families such as `t3` and `c5`
([docs.ops.city: AWS](https://docs.ops.city/ops/clouds/aws)).

| Families | Status |
|---|---|
| x86_64 Nitro (`t3`, `c5`, `m5`, …) | documented by ops |
| `t4g`, `m6g`, `c6g`, `r6g` (Graviton 2) | documented; `t4g` has a NanoVMs tutorial |
| `m7g`, `c7g`, `r7g` (Graviton 3) | documented; needs nanos ≥ 0.1.49 (GICv4.1) |
| `m7i`, `c7i` | not documented; treated as x86_64; unverified |
| `m8g`, `c8g`, `r8g` (Graviton 4) | missing from ops' table; unverified |

## Klibs for a production AMI

Klibs load by resolving each other's symbols. A klib that calls into `tls` fails to start
with "missing dependencies" unless `tls` is loaded too
([nanos@0.1.56:src/kernel/klib.c:266](https://github.com/nanovms/nanos/blob/aad473aad2f73a9893d5c32be333f2796725ab82/src/kernel/klib.c#L266)).
A misspelled klib name gets only a warning from ops, and the build carries on
([ops@0.1.47:fs/manifest.go:162](https://github.com/nanovms/ops/blob/fc3195f46c54ad94a0bcce69373d67a4441e0955/fs/manifest.go#L162)).

### `cloudwatch` + `tls`: logs

- The klib registers as a console driver, so the process's stdout and stderr go to
  `PutLogEvents`. It creates the log group and the stream itself.
- Config is `cloudwatch.logging.log_group`, which defaults to the image name, and
  `log_stream`, which defaults to the instance hostname. Leave `log_stream` unset so each
  ASG instance writes its own stream.
- `cloudwatch.mem_metrics_interval` (seconds) also publishes memory metrics
  ([nanos@0.1.56:klib/cloudwatch.c:835-860](https://github.com/nanovms/nanos/blob/aad473aad2f73a9893d5c32be333f2796725ab82/klib/cloudwatch.c#L835-L860)).
- It connects with `tls_connect` (`cloudwatch.c:307`), so `tls` must be in `Klibs`.
- Credentials and region come from instance metadata. The request is a plain GET without an
  IMDSv2 token
  ([nanos@0.1.56:klib/aws.c:12](https://github.com/nanovms/nanos/blob/aad473aad2f73a9893d5c32be333f2796725ab82/klib/aws.c#L12),
  [:96](https://github.com/nanovms/nanos/blob/aad473aad2f73a9893d5c32be333f2796725ab82/klib/aws.c#L96)).
  From the source, this means the launch template needs `HttpTokens: optional` (IMDSv1).
  That is a security trade-off (SSRF to credentials), and it is unverified on a live instance.
- The instance role needs `logs:CreateLogGroup`, `logs:CreateLogStream` and
  `logs:PutLogEvents`, plus `cloudwatch:PutMetricData` if metrics are on.

### `userdata` + `tls`: environment

- The klib reads EC2 user data with an IMDSv2 token, and turns each `KEY=value` line into an
  environment variable; lines starting with `#` are comments
  ([nanos@0.1.56:klib/userdata.c:49-57](https://github.com/nanovms/nanos/blob/aad473aad2f73a9893d5c32be333f2796725ab82/klib/userdata.c#L49-L57),
  [:143-177](https://github.com/nanovms/nanos/blob/aad473aad2f73a9893d5c32be333f2796725ab82/klib/userdata.c#L143-L177)).
- It uses mbedtls' base64 decoder, which lives in the `tls` klib.
- The klib's name is `userdata`, as in `ls ~/.ops/0.1.56*/klibs`. Some ops docs call it
  `userdata_env`; that name is only warned about and never loaded.
- One user-data document then configures a launch template version, without rebuilding the
  AMI. Secrets in user data are readable by anyone allowed `ec2:DescribeInstanceAttribute`.
  Fetching secrets at startup from SSM or Secrets Manager with the instance role avoids that.
- `cloud_init` is a different mechanism: it downloads files or a JSON environment from URLs
  you configure, and it does not read EC2 user data.

### `firewall` (optional)

- `ManifestPassthrough.firewall.rules[]` matches on source IP and destination port, with
  `accept`/`drop` actions evaluated in order. ops adds the klib whenever the key is present
  ([ops@0.1.47:lepton/image.go:361](https://github.com/nanovms/ops/blob/fc3195f46c54ad94a0bcce69373d67a4441e0955/lepton/image.go#L361)).
- The security group already restricts inbound traffic to the ALB. A catch-all `drop` rule
  can also drop replies to the instance's own outbound connections (RDS, IMDS, CloudWatch).
  So the firewall adds little here, and any ruleset needs a test before use.

### `sandbox` (optional)

- It adds OpenBSD-style `pledge`/`unveil` syscalls and restricts nothing unless the program
  calls them. A Node app would need a native addon to do that.
- It is not useful without app changes.

### `ntp` (recommended)

Point `ntp_servers` at the Amazon Time Sync Service, `169.254.169.123`. TLS certificate checks
against RDS depend on a correct clock.

## Read-only root filesystem

- Nanos supports it with `"ManifestPassthrough": {"readonly_rootfs": "true"}`
  ([docs.ops.city: volumes](https://docs.ops.city/ops/volumes)). Writes to the root
  filesystem then fail with `EROFS`.
- The kernel only checks that the key is *present*
  ([nanos@0.1.56:src/kernel/stage3.c:69](https://github.com/nanovms/nanos/blob/aad473aad2f73a9893d5c32be333f2796725ab82/src/kernel/stage3.c#L69)),
  so `"readonly_rootfs": "false"` also turns it on. To turn it off, leave the key out.
- Attached volumes (`Mounts`) are separate filesystems and stay writable.
- There is no manifest option that mounts a tmpfs at `/tmp`. Anything that writes to
  `os.tmpdir()` (multipart uploads, some caches) needs a mounted volume, or a writable root.
  The API as described (stdout logs, config from env) writes nothing, but that is unverified
  for its dependencies.

## Shutdown: what Node sees

EC2 stop and terminate both press the virtual ACPI power button. EC2 forces the instance off
if the OS has not shut down after a few minutes
([AWS: stop](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/how-ec2-instance-stop-start-works.html),
[AWS: terminate](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/how-ec2-instance-termination-works.html)).

1. Nanos handles the power button by sending **SIGTERM to the process**
   ([nanos@0.1.56:src/drivers/acpi.c:253-257](https://github.com/nanovms/nanos/blob/aad473aad2f73a9893d5c32be333f2796725ab82/src/drivers/acpi.c#L253-L257),
   [src/kernel/kernel.c:326-329](https://github.com/nanovms/nanos/blob/aad473aad2f73a9893d5c32be333f2796725ab82/src/kernel/kernel.c#L326-L329),
   [src/unix/unix.c:757-778](https://github.com/nanovms/nanos/blob/aad473aad2f73a9893d5c32be333f2796725ab82/src/unix/unix.c#L757-L778)).
2. It then waits up to **30 seconds**, and powers off when the process exits or the time runs
   out. The 30 s is compile-time (`UNIX_SHUTDOWN_TIMEOUT_SECS`,
   [src/config.h:99](https://github.com/nanovms/nanos/blob/aad473aad2f73a9893d5c32be333f2796725ab82/src/config.h#L99)).

So the API handles `SIGTERM`: it stops accepting connections, closes the pool and exits
within 30 s.

**Tested, under QEMU only.** The acceptance tests press the power button with QMP
`system_powerdown`, and Node receives SIGTERM on both architectures (`sigterm-on-powerdown`).
On x86 this is the same ACPI power-button path EC2 uses.

**Graviton is unverified.** QEMU's arm64 machine signals the button through a GPIO that Nanos
knows about. Graviton reportedly signals it through an ACPI GPIO event (`_AEI`), which Nanos
does not implement (no `_AEI` in the nanos source). If that holds, a Graviton instance never
sees SIGTERM and EC2 powers it off after its timeout. Test this before choosing Graviton (see
the open questions).

With an ASG attached to the ALB target group, the ASG deregisters an instance and waits out
the target group's deregistration delay *before* terminating it. Connection draining
therefore does not depend on SIGTERM. Keep the deregistration delay short (for example 30 s)
so instance refresh stays quick.

## Commands

### IAM for the image builder

- `ops image create -t aws` uploads the disk image with the EBS direct APIs and registers the
  AMI from the snapshot. It does not use VM Import or S3
  ([ops@0.1.47:provider/aws/aws_image.go](https://github.com/nanovms/ops/blob/fc3195f46c54ad94a0bcce69373d67a4441e0955/provider/aws/aws_image.go)).
- ops still requires `CloudConfig.BucketName` to be set
  ([ops@0.1.47:cmd/cmd_image.go:96](https://github.com/nanovms/ops/blob/fc3195f46c54ad94a0bcce69373d67a4441e0955/cmd/cmd_image.go#L96)).
- In CI, assume this role through GitHub OIDC (`aws-actions/configure-aws-credentials`), so
  no access keys are stored.

```sh
cat > ops-image-builder-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "ec2:DescribeRegions", "ec2:DescribeImages", "ec2:RegisterImage", "ec2:CreateTags",
      "ebs:StartSnapshot", "ebs:PutSnapshotBlock", "ebs:CompleteSnapshot"
    ],
    "Resource": "*"
  }]
}
EOF
aws iam create-policy --policy-name ops-image-builder --policy-document file://ops-image-builder-policy.json
# Trust policy: token.actions.githubusercontent.com, sub = repo:inmotionvr/<api-repo>:ref:refs/heads/main
aws iam create-role --role-name ops-image-builder --assume-role-policy-document file://github-oidc-trust.json
aws iam attach-role-policy --role-name ops-image-builder \
  --policy-arn arn:aws:iam::<account>:policy/ops-image-builder
```

### Instance role

```sh
cat > corpus-api-instance-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
    "Resource": "arn:aws:logs:eu-west-1:<account>:log-group:corpus-api*"
  }]
}
EOF
aws iam create-role --role-name corpus-api --assume-role-policy-document file://ec2-trust.json
aws iam put-role-policy --role-name corpus-api --policy-name logs \
  --policy-document file://corpus-api-instance-policy.json
aws iam create-instance-profile --instance-profile-name corpus-api
aws iam add-role-to-instance-profile --instance-profile-name corpus-api --role-name corpus-api
```

### AMI per architecture

The ops config for the API image (arm64; for x86_64 use `"Flavor": "m6i.large"` or `t3`):

```json
{
  "Args": ["/app/src/main.ts"],
  "DisableArgsCopy": true,
  "Dirs": ["app"],
  "Klibs": ["tls", "userdata", "cloudwatch", "ntp"],
  "ManifestPassthrough": {
    "cloudwatch": { "logging": { "log_group": "corpus-api" } },
    "ntp_servers": ["169.254.169.123"]
  },
  "RunConfig": { "Ports": ["8080"] },
  "CloudConfig": {
    "Zone": "eu-west-1",
    "BucketName": "unused-but-required-by-ops",
    "Flavor": "m7g.large",
    "Tags": [{ "key": "service", "value": "corpus-api" }]
  }
}
```

```sh
# Verify and load the package (README, "Consuming the package"), then build the AMI.
ops pkg add node_24.22.1_linux-arm64.tar.gz --name node_24.22.1 --arch arm64
ops image create --package node_24.22.1 --local --arch arm64 --nanos-version 0.1.56 \
  -t aws -c ops-aws-arm64.json -i corpus-api-arm64-$GIT_SHA

ops pkg add node_24.22.1_linux-x64.tar.gz --name node_24.22.1 --arch amd64
ops image create --package node_24.22.1 --local --arch amd64 --nanos-version 0.1.56 \
  -t aws -c ops-aws-x64.json -i corpus-api-x64-$GIT_SHA

AMI=$(aws ec2 describe-images --owners self --filters "Name=name,Values=corpus-api-arm64-$GIT_SHA" \
  --query 'Images[0].ImageId' --output text)
```

The image name must be unique per build; ops refuses to overwrite an existing AMI.

### Launch template and instance refresh

```sh
cat > userdata.env <<'EOF'
# KEY=value per line, read by the userdata klib
NODE_ENV=production
PGHOST=corpus.cluster-xxxx.eu-west-1.rds.amazonaws.com
PGSSLMODE=verify-full
NODE_EXTRA_CA_CERTS=/app/certs/rds-global-bundle.pem
EOF

aws ec2 create-launch-template-version --launch-template-name corpus-api --source-version '$Latest' \
  --launch-template-data "$(jq -n --arg ami "$AMI" --arg ud "$(base64 < userdata.env)" '{
    ImageId: $ami,
    InstanceType: "m7g.large",
    IamInstanceProfile: { Name: "corpus-api" },
    MetadataOptions: { HttpEndpoint: "enabled", HttpTokens: "optional", HttpPutResponseHopLimit: 1 },
    UserData: $ud
  }')"

aws elbv2 modify-target-group-attributes --target-group-arn "$TG_ARN" \
  --attributes Key=deregistration_delay.timeout_seconds,Value=30

aws autoscaling start-instance-refresh --auto-scaling-group-name corpus-api \
  --preferences '{"MinHealthyPercentage": 50, "InstanceWarmup": 60}'
```

`HttpTokens: optional` is there for the cloudwatch klib (see above). If logs go elsewhere,
use `required`.

## Open questions for a staging test

1. Graviton shutdown: run `aws ec2 stop-instances` on a `t4g` and an `m7g` instance, and look
   for the app's SIGTERM log line in CloudWatch. Repeat on x86 for comparison.
2. Whether the cloudwatch klib works with `HttpTokens: required`.
3. Whether `userdata` has set the environment before Node starts. Klib initialisation is
   asynchronous; this was not traced in the source.
4. Graviton 4 (`m8g`) and `m7i`: boot an AMI built with a listed family.
5. `readonly_rootfs` with the real API and its dependencies.
