import { defineStore } from 'pinia'
import { computed, ref } from 'vue'
import { api } from '@/api'
import type { ActionResponse, HealthStatus } from '@/types'

/**
 * Health / tunnel status store. The status comes from cloudflared's /ready
 * (edge connections), the same signal the container healthcheck uses.
 */
export const useTunnelStore = defineStore('tunnel', () => {
  const health = ref<HealthStatus | null>(null)
  const actionLoading = ref(false)
  const error = ref<string | null>(null)
  let pollInterval: ReturnType<typeof setInterval> | null = null

  const tunnelStatus = computed(() => health.value?.tunnel.status ?? 'unknown')
  const isRunning = computed(() => health.value?.process_running === true)

  async function fetchHealth() {
    try {
      health.value = await api<HealthStatus>('/api/health')
    } catch (e: unknown) {
      health.value = null
      error.value = e instanceof Error ? e.message : String(e)
    }
  }

  async function action(endpoint: 'start' | 'stop' | 'restart'): Promise<ActionResponse> {
    actionLoading.value = true
    error.value = null
    try {
      const result = await api<ActionResponse>(`/api/tunnel/${endpoint}`, { method: 'POST' })
      await fetchHealth()
      return result
    } catch (e: unknown) {
      error.value = e instanceof Error ? e.message : String(e)
      throw e
    } finally {
      actionLoading.value = false
    }
  }

  function startPolling(intervalMs = 4000) {
    stopPolling()
    fetchHealth()
    pollInterval = setInterval(fetchHealth, intervalMs)
  }

  function stopPolling() {
    if (pollInterval) {
      clearInterval(pollInterval)
      pollInterval = null
    }
  }

  return {
    health,
    actionLoading,
    error,
    tunnelStatus,
    isRunning,
    fetchHealth,
    action,
    startPolling,
    stopPolling,
  }
})
