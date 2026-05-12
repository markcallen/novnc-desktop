import * as assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  ACTIVE_WINDOW_UNAVAILABLE,
  buildBaseUrl,
  extractActiveWindowName,
  parseTcpPort,
  readActiveWindowName
} from '../tests/helpers';

test('parseTcpPort accepts valid ports and buildBaseUrl omits default ports', () => {
  assert.equal(parseTcpPort('443', 'novncHttpsPort'), 443);
  assert.equal(parseTcpPort(8080, 'novncHttpPort'), 8080);
  assert.equal(
    buildBaseUrl('https', '203.0.113.10', 443),
    'https://203.0.113.10'
  );
  assert.equal(
    buildBaseUrl('http', '203.0.113.10', 8080),
    'http://203.0.113.10:8080'
  );
});

test('parseTcpPort rejects blank, non-numeric, and out-of-range values', () => {
  assert.throws(() => parseTcpPort('', 'novncHttpPort'), /novncHttpPort/);
  assert.throws(() => parseTcpPort('abc', 'novncHttpPort'), /novncHttpPort/);
  assert.throws(() => parseTcpPort(0, 'novncHttpPort'), /novncHttpPort/);
  assert.throws(() => parseTcpPort(70000, 'novncHttpPort'), /novncHttpPort/);
});

test('extractActiveWindowName parses xwininfo output', () => {
  assert.equal(
    extractActiveWindowName(
      'xwininfo: Window id: 0x4200007 "SMOKE_READY": "xterm"'
    ),
    'SMOKE_READY'
  );
});

test('readActiveWindowName returns a sentinel on transient lookup failures', () => {
  assert.equal(
    readActiveWindowName(() => {
      throw new Error('xprop failed');
    }),
    ACTIVE_WINDOW_UNAVAILABLE
  );

  assert.equal(
    readActiveWindowName((command) =>
      command.includes('_NET_ACTIVE_WINDOW') ? '0x0' : 'unused'
    ),
    ACTIVE_WINDOW_UNAVAILABLE
  );
});
