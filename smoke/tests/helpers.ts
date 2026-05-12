export const ACTIVE_WINDOW_UNAVAILABLE = 'ACTIVE_WINDOW_UNAVAILABLE';

export function parseTcpPort(value: unknown, fieldName: string): number {
  const port =
    typeof value === 'number'
      ? value
      : typeof value === 'string' && value.trim() !== ''
        ? Number(value)
        : Number.NaN;

  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(
      `${fieldName} must be an integer TCP port between 1 and 65535. Received: ${String(value)}`
    );
  }

  return port;
}

export function buildBaseUrl(
  protocol: 'http' | 'https',
  host: string,
  port: number
): string {
  const defaultPort = protocol === 'http' ? 80 : 443;
  return `${protocol}://${host}${port === defaultPort ? '' : `:${port}`}`;
}

export function extractActiveWindowName(details: string): string | null {
  const match = details.match(/Window id: .*?"([^"]+)"/);
  return match?.[1] ?? null;
}

export function readActiveWindowName(ssh: (command: string) => string): string {
  try {
    const windowId = ssh(
      "DISPLAY=:1 xprop -root _NET_ACTIVE_WINDOW | awk '{print $5}'"
    ).trim();

    if (!/^0x[0-9a-f]+$/i.test(windowId) || windowId === '0x0') {
      return ACTIVE_WINDOW_UNAVAILABLE;
    }

    const details = ssh(`DISPLAY=:1 xwininfo -id ${windowId} -wm`);
    return extractActiveWindowName(details) ?? ACTIVE_WINDOW_UNAVAILABLE;
  } catch {
    return ACTIVE_WINDOW_UNAVAILABLE;
  }
}
