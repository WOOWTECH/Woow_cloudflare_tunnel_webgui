import { getCsrfToken } from '@/composables/useCsrf'

/**
 * fetch wrapper for the backend API: JSON in and out, the CSRF header on
 * every state-changing request, and readable errors (FastAPI 422 detail
 * arrays become "field: message").
 */

function formatDetail(detail: unknown): string {
  if (typeof detail === 'string') return detail
  if (Array.isArray(detail)) {
    return detail
      .map((d) => {
        const loc = Array.isArray(d?.loc) ? d.loc.slice(1).join('.') : ''
        return loc ? `${loc}: ${d?.msg ?? ''}` : String(d?.msg ?? '')
      })
      .filter(Boolean)
      .join('; ')
  }
  return JSON.stringify(detail)
}

export async function api<T>(path: string, init: RequestInit = {}): Promise<T> {
  const method = (init.method ?? 'GET').toUpperCase()
  const headers: Record<string, string> = { 'Content-Type': 'application/json' }
  if (method !== 'GET' && method !== 'HEAD') headers['x-csrftoken'] = getCsrfToken()
  const res = await fetch(path, { ...init, headers: { ...headers, ...(init.headers as object) } })
  if (!res.ok) {
    let message = `HTTP ${res.status}`
    try {
      const body = await res.json()
      if (body?.detail !== undefined) message = formatDetail(body.detail)
    } catch {
      /* non-JSON error body */
    }
    throw new Error(message)
  }
  return res.json() as Promise<T>
}

export function wsUrl(path: string): string {
  const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
  return `${protocol}//${window.location.host}${path}`
}
