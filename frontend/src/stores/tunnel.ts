import { defineStore } from 'pinia'
import { ref } from 'vue'
import type { TunnelStatus, ActionResponse } from '@/types'
import { getCsrfToken } from '@/composables/useCsrf'

export const useTunnelStore = defineStore('tunnel', () => {
  const status = ref<TunnelStatus | null>(null)
  const loading = ref(false)
  const actionLoading = ref(false)
  const error = ref<string | null>(null)
  let pollInterval: ReturnType<typeof setInterval> | null = null

  async function fetchStatus() {
    try {
      const res = await fetch('/api/tunnel/status')
      if (!res.ok) throw new Error(await res.text())
      status.value = await res.json()
    } catch (e: unknown) {
      error.value = e instanceof Error ? e.message : String(e)
    }
  }

  async function action(
    endpoint: 'start' | 'stop' | 'restart'
  ): Promise<ActionResponse> {
    actionLoading.value = true
    error.value = null
    try {
      const csrf = getCsrfToken()
      const res = await fetch(`/api/tunnel/${endpoint}`, {
        method: 'POST',
        headers: { 'x-csrftoken': csrf },
      })
      if (!res.ok) throw new Error(await res.text())
      const result: ActionResponse = await res.json()
      await fetchStatus()
      return result
    } catch (e: unknown) {
      error.value = e instanceof Error ? e.message : String(e)
      throw e
    } finally {
      actionLoading.value = false
    }
  }

  function startPolling(intervalMs = 5000) {
    stopPolling()
    fetchStatus()
    pollInterval = setInterval(fetchStatus, intervalMs)
  }

  function stopPolling() {
    if (pollInterval) {
      clearInterval(pollInterval)
      pollInterval = null
    }
  }

  return {
    status,
    loading,
    actionLoading,
    error,
    fetchStatus,
    action,
    startPolling,
    stopPolling,
  }
})
