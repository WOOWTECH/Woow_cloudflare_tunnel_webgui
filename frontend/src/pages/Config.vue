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
          <!-- Mode -->
          <div>
            <label class="block text-sm font-medium text-gray-700">Mode</label>
            <p class="mb-1 text-xs text-gray-400">
              local 使用本機憑證 (cert.pem);token 使用 Cloudflare Tunnel Token
            </p>
            <select
              v-model="form.mode"
              class="mt-1 block w-full rounded-lg border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-cf-orange focus:outline-none focus:ring-1 focus:ring-cf-orange"
            >
              <option value="local">local</option>
              <option value="token">token</option>
            </select>
          </div>

          <!-- Tunnel Token -->
          <div>
            <label class="block text-sm font-medium text-gray-700">Tunnel Token</label>
            <p class="mb-1 text-xs text-gray-400">儲存在 /data,不落 settings.json。留空則保留現有 token。</p>
            <TokenInput
              :masked-value="configStore.config?.tunnel_token_masked ?? ''"
              placeholder="eyJhIjoiLi4uIiwidCI6Ii4uLiIsInMiOiIuLi4ifQ=="
              @update:token="form.tunnel_token = $event"
            />
          </div>

          <!-- Tunnel Name -->
          <div>
            <label class="block text-sm font-medium text-gray-700">Tunnel Name</label>
            <p class="mb-1 text-xs text-gray-400">Cloudflare Tunnel name for identification</p>
            <input
              v-model="form.tunnel_name"
              type="text"
              placeholder="my-tunnel"
              class="mt-1 block w-full rounded-lg border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-cf-orange focus:outline-none focus:ring-1 focus:ring-cf-orange"
            />
          </div>
        </div>
      </fieldset>

      <!-- Routes -->
      <fieldset class="rounded-xl border border-gray-200 bg-white p-5 shadow-sm">
        <legend class="px-2 text-sm font-semibold text-gray-700">Routes</legend>
        <p class="mt-1 mb-3 text-xs text-gray-400">
          Route additional hostnames through the tunnel to local services
        </p>
        <RouteEditor
          :routes="form.routes"
          @update:routes="form.routes = $event"
        />
      </fieldset>

      <!-- Catch-All Service -->
      <fieldset class="rounded-xl border border-gray-200 bg-white p-5 shadow-sm">
        <legend class="px-2 text-sm font-semibold text-gray-700">Catch-All Service</legend>
        <div class="mt-2 space-y-4">
          <div>
            <label class="block text-sm font-medium text-gray-700">Catch-All Service URL</label>
            <p class="mb-1 text-xs text-gray-400">
              Fallback service for unmatched hostnames.
            </p>
            <input
              v-model="form.catch_all_service"
              type="text"
              placeholder="http://localhost:80"
              class="mt-1 block w-full rounded-lg border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-cf-orange focus:outline-none focus:ring-1 focus:ring-cf-orange"
            />
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

          <!-- No TLS Verify -->
          <div class="flex items-center justify-between">
            <div>
              <span class="text-sm font-medium text-gray-700">No TLS Verify</span>
              <p class="text-xs text-gray-400">Skip origin TLS certificate verification (no-tls-verify)</p>
            </div>
            <button
              type="button"
              class="relative inline-flex h-6 w-11 shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200"
              :class="form.no_tls_verify ? 'bg-cf-orange' : 'bg-gray-200'"
              @click="form.no_tls_verify = !form.no_tls_verify"
            >
              <span
                class="pointer-events-none inline-block h-5 w-5 rounded-full bg-white shadow ring-0 transition-transform duration-200"
                :class="form.no_tls_verify ? 'translate-x-5' : 'translate-x-0'"
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
              <option value="trace">trace</option>
              <option value="debug">debug</option>
              <option value="info">info</option>
              <option value="notice">notice</option>
              <option value="warn">warn</option>
              <option value="warning">warning</option>
              <option value="error">error</option>
              <option value="fatal">fatal</option>
            </select>
          </div>

          <!-- Run Parameters -->
          <div>
            <label class="block text-sm font-medium text-gray-700">Run Parameters</label>
            <input
              v-model="form.run_parameters"
              type="text"
              placeholder="--protocol quic --edge-ip-version auto"
              class="mt-1 block w-full rounded-lg border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-cf-orange focus:outline-none focus:ring-1 focus:ring-cf-orange"
            />
            <p class="mt-1 text-xs text-gray-400">Additional cloudflared run parameters</p>
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
import RouteEditor from '@/components/RouteEditor.vue'
import type { TunnelConfigUpdate, Route } from '@/types'

const configStore = useConfigStore()
const tunnelStore = useTunnelStore()

const form = reactive<TunnelConfigUpdate>({
  tunnel_token: null,
  mode: 'local',
  tunnel_name: '',
  routes: [],
  catch_all_service: '',
  post_quantum: false,
  log_level: 'info',
  run_parameters: '',
  no_tls_verify: true,
})

function resetForm() {
  const c = configStore.config
  if (c) {
    form.tunnel_token = null
    form.mode = c.mode
    form.tunnel_name = c.tunnel_name
    form.routes = (c.routes || []).map((r: Route) => ({ ...r }))
    form.catch_all_service = c.catch_all_service
    form.post_quantum = c.post_quantum
    form.log_level = c.log_level
    form.run_parameters = c.run_parameters
    form.no_tls_verify = c.no_tls_verify
  }
}

function payload(): TunnelConfigUpdate {
  return {
    tunnel_token: form.tunnel_token,
    mode: form.mode,
    tunnel_name: form.tunnel_name,
    routes: form.routes.map((r) => ({ ...r })),
    catch_all_service: form.catch_all_service,
    post_quantum: form.post_quantum,
    log_level: form.log_level,
    run_parameters: form.run_parameters,
    no_tls_verify: form.no_tls_verify,
  }
}

async function onSave() {
  await configStore.updateConfig(payload())
}

async function onSaveAndRestart() {
  await configStore.updateConfig(payload())
  if (!configStore.error) {
    await tunnelStore.action('restart').catch(() => {
      // If process isn't running, start instead
      tunnelStore.action('start').catch(() => {})
    })
  }
}

watch(() => configStore.config, resetForm, { immediate: true })

onMounted(() => {
  configStore.fetchConfig()
})
</script>
