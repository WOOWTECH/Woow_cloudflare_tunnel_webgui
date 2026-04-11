<template>
  <div class="space-y-6">
    <h1 class="text-2xl font-bold text-gray-900">Configuration</h1>

    <div v-if="configStore.loading && !configStore.config" class="text-gray-500">
      Loading...
    </div>

    <form v-else @submit.prevent="onSave" class="space-y-6">
      <!-- Basic Settings -->
      <fieldset class="rounded-xl border border-gray-200 bg-white p-5 shadow-sm">
        <legend class="px-2 text-sm font-semibold text-gray-700">Basic Settings</legend>
        <div class="mt-2 space-y-4">
          <!-- Tunnel Token -->
          <div>
            <label class="block text-sm font-medium text-gray-700">Tunnel Token</label>
            <p class="mb-1 text-xs text-gray-400">Stored as podman secret, never saved to disk</p>
            <TokenInput
              :masked-value="configStore.config?.tunnel_token_masked ?? ''"
              placeholder="eyJhIjoiLi4uIiwidCI6Ii4uLiIsInMiOiIuLi4ifQ=="
              @update:token="form.tunnel_token = $event"
            />
          </div>

          <!-- Container Name -->
          <div>
            <label class="block text-sm font-medium text-gray-700">Container Name</label>
            <input
              v-model="form.container_name"
              type="text"
              class="mt-1 block w-full rounded-lg border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-cf-orange focus:outline-none focus:ring-1 focus:ring-cf-orange"
            />
          </div>

          <!-- Container Image -->
          <div>
            <label class="block text-sm font-medium text-gray-700">Container Image</label>
            <input
              v-model="form.container_image"
              type="text"
              class="mt-1 block w-full rounded-lg border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-cf-orange focus:outline-none focus:ring-1 focus:ring-cf-orange"
            />
            <p class="mt-1 text-xs text-gray-400">Only cloudflare/cloudflared images allowed</p>
          </div>
        </div>
      </fieldset>

      <!-- Advanced Settings -->
      <fieldset class="rounded-xl border border-gray-200 bg-white p-5 shadow-sm">
        <legend class="px-2 text-sm font-semibold text-gray-700">Advanced Settings</legend>
        <div class="mt-2 space-y-4">
          <!-- Post-Quantum -->
          <div class="flex items-center justify-between">
            <div>
              <span class="text-sm font-medium text-gray-700">Post-Quantum Crypto</span>
              <p class="text-xs text-gray-400">Use post-quantum key agreement for tunnel connections</p>
            </div>
            <button
              type="button"
              class="relative inline-flex h-6 w-11 shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200"
              :class="form.post_quantum ? 'bg-cf-orange' : 'bg-gray-200'"
              @click="form.post_quantum = !form.post_quantum"
            >
              <span
                class="pointer-events-none inline-block h-5 w-5 rounded-full bg-white shadow ring-0 transition-transform duration-200"
                :class="form.post_quantum ? 'translate-x-5' : 'translate-x-0'"
              />
            </button>
          </div>

          <!-- Log Level -->
          <div>
            <label class="block text-sm font-medium text-gray-700">Log Level</label>
            <select
              v-model="form.log_level"
              class="mt-1 block w-full rounded-lg border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-cf-orange focus:outline-none focus:ring-1 focus:ring-cf-orange"
            >
              <option value="debug">debug</option>
              <option value="info">info</option>
              <option value="warn">warn</option>
              <option value="error">error</option>
              <option value="fatal">fatal</option>
            </select>
          </div>

          <!-- Extra Args -->
          <div>
            <label class="block text-sm font-medium text-gray-700">Extra CLI Arguments</label>
            <input
              v-model="form.extra_args"
              type="text"
              placeholder="--protocol quic --edge-ip-version auto"
              class="mt-1 block w-full rounded-lg border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-cf-orange focus:outline-none focus:ring-1 focus:ring-cf-orange"
            />
            <p class="mt-1 text-xs text-gray-400">Additional cloudflared CLI flags</p>
          </div>
        </div>
      </fieldset>

      <!-- Actions -->
      <div class="flex items-center gap-3">
        <button
          type="submit"
          class="rounded-lg bg-cf-orange px-5 py-2 text-sm font-medium text-white shadow-sm hover:bg-orange-600 disabled:opacity-50"
          :disabled="configStore.loading"
        >
          {{ configStore.loading ? 'Saving...' : 'Save' }}
        </button>
        <button
          type="button"
          class="rounded-lg bg-cf-orange px-5 py-2 text-sm font-medium text-white shadow-sm hover:bg-orange-600 disabled:opacity-50"
          :disabled="configStore.loading || tunnelStore.actionLoading"
          @click="onSaveAndRestart"
        >
          Save & Restart
        </button>
        <button
          type="button"
          class="rounded-lg border border-gray-300 bg-white px-5 py-2 text-sm font-medium text-gray-700 shadow-sm hover:bg-gray-50"
          @click="resetForm"
        >
          Cancel
        </button>
      </div>

      <!-- Feedback -->
      <div
        v-if="configStore.saved"
        class="rounded-lg border border-green-200 bg-green-50 px-4 py-3 text-sm text-green-700"
      >
        Configuration saved successfully.
      </div>
      <div
        v-if="configStore.error"
        class="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700"
      >
        {{ configStore.error }}
      </div>
    </form>
  </div>
</template>

<script setup lang="ts">
import { reactive, onMounted, watch } from 'vue'
import { useConfigStore } from '@/stores/config'
import { useTunnelStore } from '@/stores/tunnel'
import TokenInput from '@/components/TokenInput.vue'
import type { TunnelConfigUpdate } from '@/types'

const configStore = useConfigStore()
const tunnelStore = useTunnelStore()

const form = reactive<TunnelConfigUpdate>({
  tunnel_token: null,
  post_quantum: false,
  log_level: 'info',
  extra_args: '',
  container_name: 'cloudflared',
  container_image: 'cloudflare/cloudflared:latest',
})

function resetForm() {
  const c = configStore.config
  if (c) {
    form.tunnel_token = null
    form.post_quantum = c.post_quantum
    form.log_level = c.log_level
    form.extra_args = c.extra_args
    form.container_name = c.container_name
    form.container_image = c.container_image
  }
}

async function onSave() {
  await configStore.updateConfig({ ...form })
}

async function onSaveAndRestart() {
  await configStore.updateConfig({ ...form })
  if (!configStore.error) {
    await tunnelStore.action('restart').catch(() => {
      // If container doesn't exist, start instead
      tunnelStore.action('start').catch(() => {})
    })
  }
}

watch(() => configStore.config, resetForm, { immediate: true })

onMounted(() => {
  configStore.fetchConfig()
})
</script>
