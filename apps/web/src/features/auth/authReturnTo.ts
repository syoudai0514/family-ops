const AUTH_RETURN_TO_KEY = 'family-ops.auth-return-to';
let memoryReturnTo: string | null = null;

export function safeReturnTo(value: string | null | undefined): string | null {
  if (
    !value ||
    !value.startsWith('/') ||
    value.startsWith('//') ||
    // eslint-disable-next-line no-control-regex -- Reject characters browsers strip from URLs.
    /[\\\u0000-\u001f\u007f]/.test(value)
  ) {
    return null;
  }
  // Browser history treats backslashes and stripped control characters as URL
  // syntax. Validate the resolved destination and callback path as browsers do.
  const baseOrigin = 'https://family-ops.invalid';
  const destination = new URL(value, baseOrigin);
  if (destination.origin !== baseOrigin || destination.pathname.startsWith('/auth/callback')) {
    return null;
  }
  return value;
}

export function rememberAuthReturnTo(value: string): void {
  const returnTo = safeReturnTo(value);
  if (!returnTo) return;
  memoryReturnTo = returnTo;
  try {
    window.sessionStorage.setItem(AUTH_RETURN_TO_KEY, returnTo);
  } catch {
    // Private/embedded browsers can deny storage. This optional navigation
    // enhancement must not prevent password sign-in or leave its form busy.
  }
}

export function consumeAuthReturnTo(): string | null {
  let value = memoryReturnTo;
  memoryReturnTo = null;
  try {
    value ??= safeReturnTo(window.sessionStorage.getItem(AUTH_RETURN_TO_KEY));
    window.sessionStorage.removeItem(AUTH_RETURN_TO_KEY);
  } catch {
    // Keep in-memory navigation available even when browser storage is denied.
  }
  return value;
}
