import { defineStore } from 'pinia'
import { ref } from 'vue'
import { api } from '@/api'
import type { TunnelConfig, TunnelConfigUpdate } from '@/types'

export const useConfigStore = defineStore('config', () => {
  const config = ref<TunnelConfig | null>(null)
  const loading = ref(false)
  const error = ref<string | null>(null)
  const saved = ref(false)

  async function fetchConfig() {
    loading.value = true
    error.value = null
    try {
      config.value = await api<TunnelConfig>('/api/config')
    } catch (e: unknown) {
      error.value = e instanceof Error ? e.message : String(e)
    } finally {
      loading.value = false
    }
  }

  /**
   * Save the settings. With restart, the backend also applies them (a fresh
   * cloudflared argv and, in local mode, a regenerated ingress config).
   */
  async function updateConfig(data: TunnelConfigUpdate, restart = false): Promise<boolean> {
    loading.value = true
    error.value = null
    saved.value = false
    try {
      config.value = await api<TunnelConfig>(`/api/config?restart=${restart}`, {
        method: 'PUT',
        body: JSON.stringify(data),
      })
      saved.value = true
      return true
    } catch (e: unknown) {
      const message = e instanceof Error ? e.message : String(e)
      // A save-and-apply can fail after the save: show what is stored now.
      if (restart) await fetchConfig()
      error.value = message
      return false
    } finally {
      loading.value = false
    }
  }

  return { config, loading, error, saved, fetchConfig, updateConfig }
})
