/**
 * Read the CSRF token from the cookie set by starlette-csrf.
 * Issues a warning if the cookie is missing (e.g. first load race condition).
 */
export function getCsrfToken(): string {
  const match = document.cookie.match(/(?:^|;\s*)csrftoken=([^;]+)/)
  const token = match ? match[1] : ''
  if (!token) {
    console.warn('[useCsrf] CSRF token not found in cookies — requests may be rejected')
  }
  return token
}
