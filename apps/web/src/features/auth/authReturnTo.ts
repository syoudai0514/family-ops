const AUTH_RETURN_TO_KEY = 'family-ops.auth-return-to';

export function safeReturnTo(value: string | null | undefined): string | null {
  if (!value || !value.startsWith('/') || value.startsWith('//') || value.startsWith('/auth/callback')) {
    return null;
  }
  return value;
}

export function rememberAuthReturnTo(value: string): void {
  const returnTo = safeReturnTo(value);
  if (returnTo) window.sessionStorage.setItem(AUTH_RETURN_TO_KEY, returnTo);
}

export function consumeAuthReturnTo(): string | null {
  const value = safeReturnTo(window.sessionStorage.getItem(AUTH_RETURN_TO_KEY));
  window.sessionStorage.removeItem(AUTH_RETURN_TO_KEY);
  return value;
}
