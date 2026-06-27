import { defineStore } from 'pinia'
import { ref } from 'vue'
import { getCsrfToken } from '@/composables/useCsrf'
import type { Route, SetupMode, SetupStateResponse } from '@/types'

export const useSetupStore = defineStore('setup', () => {
  const hasCert = ref(false)
  const hasTunnel = ref(false)
  const tunnelUuid = ref<string | null>(null)
  const mode = ref<SetupMode>('local')
  const loading = ref(false)
  const error = ref<string | null>(null)

  async function fetchState(): Promise<void> {
    loading.value = true
    error.value = null
    try {
      const res = await fetch('/api/setup/state')
      if (!res.ok) throw new Error(await res.text())
      const data = (await res.json()) as SetupStateResponse
      hasCert.value = data.has_cert
      hasTunnel.value = data.has_tunnel
      tunnelUuid.value = data.tunnel_uuid
      mode.value = data.mode
    } catch (e: unknown) {
      error.value = e instanceof Error ? e.message : String(e)
    } finally {
      loading.value = false
    }
  }

  async function createTunnel(tunnelName: string): Promise<boolean> {
    loading.value = true
    error.value = null
    try {
      const res = await fetch('/api/setup/tunnel', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'x-csrftoken': getCsrfToken(),
        },
        body: JSON.stringify({ tunnel_name: tunnelName }),
      })
      if (!res.ok) throw new Error(await readError(res))
      const data = (await res.json()) as { tunnel_uuid: string }
      tunnelUuid.value = data.tunnel_uuid
      hasTunnel.value = true
      return true
    } catch (e: unknown) {
      error.value = e instanceof Error ? e.message : String(e)
      return false
    } finally {
      loading.value = false
    }
  }

  async function apply(routes: Route[], catchAllService: string): Promise<boolean> {
    loading.value = true
    error.value = null
    try {
      const res = await fetch('/api/setup/apply', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'x-csrftoken': getCsrfToken(),
        },
        body: JSON.stringify({ routes, catch_all_service: catchAllService }),
      })
      if (!res.ok) throw new Error(await readError(res))
      return true
    } catch (e: unknown) {
      error.value = e instanceof Error ? e.message : String(e)
      return false
    } finally {
      loading.value = false
    }
  }

  /** Extract a `{detail}` (FastAPI 422/HTTPException) message, falling back to text/status. */
  async function readError(res: Response): Promise<string> {
    try {
      const data = (await res.json()) as { detail?: unknown }
      if (typeof data.detail === 'string') return data.detail
      if (data.detail != null) return JSON.stringify(data.detail)
    } catch {
      /* not JSON — fall through */
    }
    return `請求失敗(${res.status})`
  }

  return {
    hasCert,
    hasTunnel,
    tunnelUuid,
    mode,
    loading,
    error,
    fetchState,
    createTunnel,
    apply,
  }
})
