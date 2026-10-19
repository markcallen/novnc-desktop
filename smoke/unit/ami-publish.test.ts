import * as assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import {
  chmodSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

function preview(
  script: string,
  env: Record<string, string> = {},
  args: string[] = []
) {
  const result = spawnSync('bash', [script, ...args, '--dry-run'], {
    encoding: 'utf8',
    env: { ...process.env, ...env }
  });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout;
}

test('public single-region build selects only Elementary and reserves one public slot', () => {
  const output = preview('scripts/build-ami.sh', { AMI_PUBLIC: 'true' });
  assert.match(output, /quota room for 1 new public AMI/);
  assert.match(
    output,
    /packer build -only=novnc-desktop-ubuntu-24\.04\.amazon-ebs\.elementary /
  );
  assert.doesNotMatch(output, /packer build -only=.*amazon-ebs\.openbox /);
});

test('private single-region build retains both variants', () => {
  const output = preview('scripts/build-ami.sh', { AMI_PUBLIC: 'false' });
  assert.match(output, /\[dry-run\] packer build -var /);
  assert.match(output, /Variants built: {2}openbox, elementary/);
});

test('multi-region public build selects only Elementary; private build retains both', () => {
  const publicOutput = preview('scripts/build-ami-multi-region.sh', {
    REGIONS: 'us-east-1',
    PRIMARY_REGION: 'us-east-1'
  });
  const privateOutput = preview(
    'scripts/build-ami-multi-region.sh',
    { REGIONS: 'us-east-1', PRIMARY_REGION: 'us-east-1' },
    ['--private']
  );
  assert.match(
    publicOutput,
    /packer build -only=novnc-desktop-ubuntu-24\.04\.amazon-ebs\.elementary /
  );
  assert.match(privateOutput, /\[dry-run\] packer build -var /);
});

test('multi-region public build stops when account-wide public AMI quota is full', () => {
  const dir = mkdtempSync(join(tmpdir(), 'novnc-ami-publish-'));
  try {
    const aws = join(dir, 'aws');
    const packer = join(dir, 'packer');
    writeFileSync(
      aws,
      '#!/bin/bash\nif [[ "$*" == *get-image-block-public-access-state* ]]; then echo unblocked; elif [[ "$*" == *tag:Variant* ]]; then echo 0; else echo 5; fi\n'
    );
    writeFileSync(packer, '#!/bin/bash\necho PACKER_INVOKED\n');
    chmodSync(aws, 0o755);
    chmodSync(packer, 0o755);

    const result = spawnSync(
      'bash',
      ['scripts/build-ami-multi-region.sh', '--public'],
      {
        encoding: 'utf8',
        env: {
          ...process.env,
          PATH: `${dir}:${process.env.PATH}`,
          REGIONS: 'us-east-1',
          PUBLIC_AMI_LIMIT: '5'
        }
      }
    );
    assert.equal(result.status, 1);
    assert.match(result.stderr, /no public AMI quota room/);
    assert.doesNotMatch(result.stdout, /PACKER_INVOKED/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('Packer never grants public launch permission to Openbox', () => {
  const template = readFileSync('packer.pkr.hcl', 'utf8');
  const openbox = template.match(
    /source "amazon-ebs" "openbox" \{([\s\S]*?)\n\}/
  )?.[1];
  assert.ok(openbox);
  assert.match(openbox, /ami_groups = \[\]/);
});
