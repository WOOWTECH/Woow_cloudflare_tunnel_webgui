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

          <!-- External Hostname -->
          <div>
            <label class="block text-sm font-medium text-gray-700">External Hostname</label>
            <p class="mb-1 text-xs text-gray-400">The public hostname for your main service (e.g. home.example.com)</p>
            <input
              v-model="form.external_hostname"
              type="text"
              placeholder="home.example.com"
              class="mt-1 block w-full rounded-lg border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-cf-orange focus:outline-none focus:ring-1 focus:ring-cf-orange"
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

      <!-- Additional Hosts -->
      <fieldset class="rounded-xl border border-gray-200 bg-white p-5 shadow-sm">
        <legend class="px-2 text-sm font-semibold text-gray-700">Additional Hosts</legend>
        <p class="mt-1 mb-3 text-xs text-gray-400">
          Route additional hostnames through the tunnel to local services
        </p>
        <div class="space-y-3">
          <div
            v-for="(host, idx) in form.additional_hosts"
            :key="idx"
            class="flex items-start gap-3 rounded-lg border border-gray-100 bg-gray-50 p-3"
          >
            <div class="flex-1 space-y-2">
              <div>
                <label class="block text-xs font-medium text-gray-600">Hostname</label>
                <input
                  v-model="host.hostname"
                  type="text"
                  placeholder="app.example.com"
                  class="mt-0.5 block w-full rounded border border-gray-300 px-2 py-1.5 text-sm focus:border-cf-orange focus:outline-none focus:ring-1 focus:ring-cf-orange"
                />
              </div>
              <div>
                <label class="block text-xs font-medium text-gray-600">Service</label>
                <input
                  v-model="host.service"
                  type="text"
                  placeholder="http://localhost:8080"
                  class="mt-0.5 block w-full rounded border border-gray-300 px-2 py-1.5 text-sm focus:border-cf-orange focus:outline-none focus:ring-1 focus:ring-cf-orange"
                />
              </div>
              <div class="flex items-center gap-2">
                <input
                  :id="'chunked-' + idx"
                  v-model="host.disableChunkedEncoding"
                  type="checkbox"
                  class="h-4 w-4 rounded border-gray-300 text-cf-orange focus:ring-cf-orange"
                />
                <label :for="'chunked-' + idx" class="text-xs text-gray-600">
                  Disable chunked transfer encoding
                </label>
              </div>
            </div>
            <button
              type="button"
              class="mt-5 rounded p-1 text-red-400 hover:bg-red-50 hover:text-red-600"
              title="Remove host"
              @click="removeHost(idx)"
            >
              <svg class="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16" />
              </svg>
            </button>
          </div>

          <button
            type="button"
            class="flex items-center gap-1.5 rounded-lg border border-dashed border-gray-300 px-3 py-2 text-sm text-gray-500 hover:border-cf-orange hover:text-cf-orange"
            @click="addHost"
          >
            <svg class="h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
            </svg>
            Add Host
          </button>
        </div>
      </fieldset>

      <!-- Catch-All / Nginx Proxy Manager -->
      <fieldset class="rounded-xl border border-gray-200 bg-white p-5 shadow-sm">
        <legend class="px-2 text-sm font-semibold text-gray-700">Catch-All Service</legend>
        <div class="mt-2 space-y-4">
          <!-- Nginx Proxy Manager -->
          <div class="flex items-center justify-between">
            <div>
              <span class="text-sm font-medium text-gray-700">Nginx Proxy Manager</span>
              <p class="text-xs text-gray-400">Enable catch-all via Nginx Proxy Manager (sets service to http://localhost:80)</p>
            </div>
            <button
              type="button"
              class="relative inline-flex h-6 w-11 shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200"
              :class="form.nginx_proxy_manager ? 'bg-cf-orange' : 'bg-gray-200'"
              @click="form.nginx_proxy_manager = !form.nginx_proxy_manager"
            >
              <span
                class="pointer-events-none inline-block h-5 w-5 rounded-full bg-white shadow ring-0 transition-transform duration-200"
                :class="form.nginx_proxy_manager ? 'translate-x-5' : 'translate-x-0'"
              />
            </button>
          </div>

          <!-- Catch-All Service URL -->
          <div>
            <label class="block text-sm font-medium text-gray-700">Catch-All Service URL</label>
            <p class="mb-1 text-xs text-gray-400">
              Fallback service for unmatched hostnames. Overridden when Nginx Proxy Manager is enabled.
            </p>
            <input
              v-model="form.catch_all_service"
              type="text"
              placeholder="http://localhost:80"
              :disabled="form.nginx_proxy_manager"
              class="mt-1 block w-full rounded-lg border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-cf-orange focus:outline-none focus:ring-1 focus:ring-cf-orange disabled:bg-gray-100 disabled:text-gray-400"
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
import type { TunnelConfigUpdate, AdditionalHost } from '@/types'

const configStore = useConfigStore()
const tunnelStore = useTunnelStore()

const form = reactive<TunnelConfigUpdate>({
  tunnel_token: null,
  post_quantum: false,
  log_level: 'info',
  extra_args: '',
  container_name: 'cloudflared',
  container_image: 'cloudflare/cloudflared:latest',
  external_hostname: '',
  additional_hosts: [],
  tunnel_name: '',
  catch_all_service: '',
  nginx_proxy_manager: false,
})

function addHost() {
  form.additional_hosts.push({
    hostname: '',
    service: '',
    disableChunkedEncoding: false,
  })
}

function removeHost(idx: number) {
  form.additional_hosts.splice(idx, 1)
}

function resetForm() {
  const c = configStore.config
  if (c) {
    form.tunnel_token = null
    form.post_quantum = c.post_quantum
    form.log_level = c.log_level
    form.extra_args = c.extra_args
    form.container_name = c.container_name
    form.container_image = c.container_image
    form.external_hostname = c.external_hostname
    form.additional_hosts = (c.additional_hosts || []).map((h: AdditionalHost) => ({ ...h }))
    form.tunnel_name = c.tunnel_name
    form.catch_all_service = c.catch_all_service
    form.nginx_proxy_manager = c.nginx_proxy_manager
  }
}

async function onSave() {
  await configStore.updateConfig({ ...form, additional_hosts: form.additional_hosts.map(h => ({ ...h })) })
}

async function onSaveAndRestart() {
  await configStore.updateConfig({ ...form, additional_hosts: form.additional_hosts.map(h => ({ ...h })) })
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
