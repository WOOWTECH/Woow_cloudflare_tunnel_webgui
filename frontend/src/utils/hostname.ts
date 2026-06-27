/**
 * Front-end hostname pre-check, kept consistent with the backend
 * `VALID_HOSTNAME_RE` in `backend/models/schemas.py`:
 * lowercase, no protocol (`://`), no port (`:`).
 */
export const VALID_HOSTNAME_RE =
  /^(([a-z0-9]|[a-z0-9][a-z0-9-]*[a-z0-9])\.)*([a-z0-9]|[a-z0-9][a-z0-9-]*[a-z0-9])$/

/**
 * Returns a human-readable error message for an invalid hostname,
 * or `null` when the hostname is valid.
 */
export function hostnameError(raw: string): string | null {
  const value = raw.trim().toLowerCase()
  if (!value) return 'hostname 不可為空'
  if (raw.includes('://')) return 'hostname 不可含協定(例如 http://)'
  if (raw.includes(':')) return 'hostname 不可含埠(例如 :8123)'
  if (!VALID_HOSTNAME_RE.test(value)) {
    return 'hostname 格式不正確(僅允許小寫字母、數字、「-」與「.」)'
  }
  return null
}
