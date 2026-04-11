import { defineStore } from 'pinia'
import { ref } from 'vue'
import type { TunnelConfig, TunnelConfigUpdate } from '@/types'
import { getCsrfToken } from '@/composables/useCsrf'

export const useConfigStore = defineStore('config', () => {
  const config = ref<TunnelConfig | null>(null)
  const loading = ref(false)
  const error = ref<string | null>(null)
  const saved = ref(false)

  async function fetchConfig() {
    loading.value = true
    error.value = null
    try {
      const res = await fetch('/api/config')
      if (!res.ok) throw new Error(await res.text())
      config.value = await res.json()
    } catch (e: unknown) {
      error.value = e instanceof Error ? e.message : String(e)
    } finally {
      loading.value = false
    }
  }

  async function updateConfig(data: TunnelConfigUpdate) {
    loading.value = true
    error.value = null
    saved.value = false
    try {
      const csrf = getCsrfToken()
      const res = await fetch('/api/config', {
        method: 'PUT',
        headers: {
          'Content-Type': 'application/json',
          'x-csrftoken': csrf,
        },
        body: JSON.stringify(data),
      })
      if (!res.ok) throw new Error(await res.text())
      config.value = await res.json()
      saved.value = true
    } catch (e: unknown) {
      error.value = e instanceof Error ? e.message : String(e)
    } finally {
      loading.value = false
    }
  }

  return { config, loading, error, saved, fetchConfig, updateConfig }
})
