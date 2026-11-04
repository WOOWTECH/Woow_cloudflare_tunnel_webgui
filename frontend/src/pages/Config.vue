<template>
  <div class="space-y-6">
    <h1 class="text-2xl font-bold text-gray-900">Configuration</h1>

    <div v-if="configStore.loading && !configStore.config" class="text-gray-500">
      Loading...
    </div>

    <form v-else @submit.prevent="onSave(false)" class="space-y-6">
      <!-- Basic Settings -->
      <fieldset class="rounded-xl border border-gray-200 bg-white p-5 shadow-sm">
        <legend class="px-2 text-sm font-semibold text-gray-700">Basic Settings</legend>
        <div class="mt-2 space-y-4">
          <!-- Mode -->
          <div>
            <label class="block text-sm font-medium text-gray-700">Mode</label>
            <p class="mb-1 text-xs text-gray-400">
              local 使用本機憑證 (cert.pem),路由在下方管理;token 使用 Cloudflare 後台或 PaaS 提供的 tunnel token
            </p>
            <select
              v-model="form.mode"
              :disabled="managedByPaas"
              class="mt-1 block w-full rounded-lg border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-cf-orange focus:outline-none focus:ring-1 focus:ring-cf-orange disabled:bg-gray-100"
            >
              <option value="local">local</option>
              <option value="token">token</option>
            </select>
          </div>

          <!-- Tunnel Token -->
          <div>
            <label class="block text-sm font-medium text-gray-700">Tunnel Token</label>
            <template v-if="!managedByPaas">
              <p class="mb-1 text-xs text-gray-400">
                儲存在 /data(權限 0600),不寫入 settings.json。可以直接貼上
                <code>cloudflared service install …</code> 整段指令。留空則保留現有 token。
              </p>
              <TokenInput
                :masked-value="configStore.config?.tunnel_token_masked ?? ''"
                placeholder="eyJhIjoiLi4uIiwidCI6Ii4uLiIsInMiOiIuLi4ifQ=="
                @update:token="tokenInput = $event"
              />
              <div class="mt-2 flex items-center gap-3">
                <span
                  class="inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium"
                  :class="configStore.config?.tunnel_token_set ? 'bg-green-100 text-green-800' : 'bg-gray-100 text-gray-600'"
                >
                  {{ configStore.config?.tunnel_token_set ? 'token configured' : 'no token' }}
                </span>
                <button
                  v-if="configStore.config?.tunnel_token_set"
                  type="button"
                  class="text-xs font-medium text-red-500 hover:text-red-700"
                  @click="toggleClearToken"
                >
                  {{ clearToken ? '儲存時保留 token' : '儲存時移除 token(改用 local 模式)' }}
                </button>
              </div>
              <p v-if="clearToken" class="mt-1 text-xs text-amber-600">儲存後會刪除目前的 token。</p>
            </template>
            <p v-else class="rounded-lg bg-blue-50 px-4 py-3 text-sm leading-6 text-blue-900">
              此憑證由 WOOW PaaS 自動管理。若要改用手動 token 或 local 模式,請先到
              <router-link to="/paas" class="font-semibold underline">PaaS 連結</router-link>
              停止連線並解除綁定。
            </p>
          </div>

          <!-- Tunnel Name -->
          <div>
            <label class="block text-sm font-medium text-gray-700">Tunnel Name</label>
            <p class="mb-1 text-xs text-gray-400">Cloudflare Tunnel 名稱(local 模式)</p>
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
          把公開 hostname 導向本機服務(容器使用 host 網路,填 http://localhost:埠)。
          「儲存並套用」時會為新的 hostname 建立 DNS。
        </p>
        <div
          v-if="form.mode === 'token'"
          class="mb-3 rounded-lg border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-700"
        >
          Token 模式下,ingress 路由由 Cloudflare 後台或 PaaS 管理。以下本地路由設定僅在
          <span class="font-medium">local</span> 模式生效。
        </div>
        <p v-else class="mb-3 rounded-lg border border-amber-200 bg-amber-50 px-3 py-2 text-xs leading-5 text-amber-900">
          移除路由或停止 tunnel,不會自動刪除 Cloudflare DNS。請到 Cloudflare DNS 檢查該網址的 CNAME,
          確認不再使用後才刪除;也請檢查對應的 Access 應用。
        </p>
        <RouteEditor :routes="form.routes" @update:routes="form.routes = $event" />
      </fieldset>

      <!-- Catch-All Service -->
      <fieldset class="rounded-xl border border-gray-200 bg-white p-5 shadow-sm">
        <legend class="px-2 text-sm font-semibold text-gray-700">Catch-All Service</legend>
        <div class="mt-2 space-y-4">
          <div>
            <label class="block text-sm font-medium text-gray-700">Catch-All Service URL</label>
            <p class="mb-1 text-xs text-gray-400">
              未符合上方 hostname 的流量,例如交給本機的 Nginx Proxy Manager:http://localhost:80
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
              <p class="text-xs text-gray-400">只使用 QUIC 傳輸,部分網路環境可能無法連線</p>
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
            <label class="block text-sm font-medium text-gray-700">cloudflared Log Level</label>
            <select
              v-model="form.log_level"
              class="mt-1 block w-full rounded-lg border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-cf-orange focus:outline-none focus:ring-1 focus:ring-cf-orange"
            >
              <option v-for="lvl in LOG_LEVELS" :key="lvl" :value="lvl">{{ lvl }}</option>
            </select>
          </div>

          <!-- Run Parameters -->
          <div>
            <label class="block text-sm font-medium text-gray-700">Run Parameters</label>
            <p class="mb-1 text-xs text-gray-400">
              一行一個,格式 --flag=value。允許:--edge-bind-address、--edge-ip-version、
              --grace-period、--ha-connections、--logfile、--loglevel、--pidfile、--protocol、
              --region、--retries、--tag
            </p>
            <textarea
              v-model="runParametersText"
              rows="3"
              placeholder="--protocol=http2&#10;--region=us"
              class="mt-1 block w-full rounded-lg border px-3 py-2 font-mono text-sm shadow-sm focus:outline-none focus:ring-1"
              :class="runParametersError ? 'border-red-300 focus:border-red-500 focus:ring-red-500' : 'border-gray-300 focus:border-cf-orange focus:ring-cf-orange'"
            />
            <p v-if="runParametersError" class="mt-1 text-xs text-red-600">{{ runParametersError }}</p>
          </div>
        </div>
      </fieldset>

      <!-- Actions -->
      <div class="flex items-center gap-3">
        <button
          type="submit"
          class="rounded-lg border border-cf-orange bg-white px-5 py-2 text-sm font-medium text-cf-orange shadow-sm hover:bg-orange-50 disabled:opacity-50"
          :disabled="configStore.loading || hasErrors"
        >
          {{ configStore.loading ? 'Saving...' : 'Save' }}
        </button>
        <button
          type="button"
          class="rounded-lg bg-cf-orange px-5 py-2 text-sm font-medium text-white shadow-sm hover:bg-orange-600 disabled:opacity-50"
          :disabled="configStore.loading || hasErrors"
          @click="onSave(true)"
        >
          Save &amp; Apply
        </button>
        <button
          type="button"
          class="rounded-lg border border-gray-300 bg-white px-5 py-2 text-sm font-medium text-gray-700 shadow-sm hover:bg-gray-50"
          @click="resetForm"
        >
          Reset
        </button>
      </div>
      <p class="text-xs text-gray-400">
        「Save」只儲存設定;「Save &amp; Apply」會以新設定重新啟動 cloudflared(local 模式會重新產生並驗證 ingress,
        並為新 hostname 建立 DNS)。tunnel 會中斷數秒。
      </p>
      <p v-if="tokenModeWithoutToken" class="text-xs text-amber-600">
        token 模式需要 tunnel token,請先貼上 token。
      </p>

      <!-- Feedback -->
      <div
        v-if="configStore.saved"
        class="rounded-lg border border-green-200 bg-green-50 px-4 py-3 text-sm text-green-700"
      >
        {{ lastSaveApplied ? '設定已儲存並套用。' : '設定已儲存(尚未套用)。' }}
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
import { computed, reactive, ref, onMounted, watch } from 'vue'
import { useConfigStore } from '@/stores/config'
import { useTunnelStore } from '@/stores/tunnel'
import TokenInput from '@/components/TokenInput.vue'
import RouteEditor from '@/components/RouteEditor.vue'
import { hostnameError } from '@/utils/hostname'
import type { LogLevel, Route, SetupMode, TunnelConfigUpdate } from '@/types'

const LOG_LEVELS: LogLevel[] = ['debug', 'info', 'warn', 'error', 'fatal']
const RUN_PARAMETER_RE =
  /^(--edge-bind-address|--edge-ip-version|--grace-period|--ha-connections|--logfile|--loglevel|--pidfile|--protocol|--region|--retries|--tag)=.*$/

const configStore = useConfigStore()
const tunnelStore = useTunnelStore()

const tokenInput = ref<string | null>(null)
const clearToken = ref(false)
const runParametersText = ref('')
const lastSaveApplied = ref(false)

const form = reactive({
  mode: 'local' as SetupMode,
  tunnel_name: '',
  routes: [] as Route[],
  catch_all_service: '',
  post_quantum: false,
  log_level: 'info' as LogLevel,
  no_tls_verify: true,
})

const managedByPaas = computed(() => !!configStore.config?.tunnel_token_managed_by_paas)

const runParameters = computed(() =>
  runParametersText.value.split('\n').map((l) => l.trim()).filter(Boolean)
)

const runParametersError = computed(() => {
  const bad = runParameters.value.find((p) => !RUN_PARAMETER_RE.test(p))
  return bad ? `'${bad}' 不是允許的 run parameter(格式:--flag=value)` : null
})

const tokenModeWithoutToken = computed(() => {
  if (form.mode !== 'token' || managedByPaas.value) return false
  if (clearToken.value) return true
  return !tokenInput.value && !configStore.config?.tunnel_token_set
})

const hasErrors = computed(
  () =>
    runParametersError.value !== null ||
    tokenModeWithoutToken.value ||
    form.routes.some((r) => hostnameError(r.hostname) !== null || !r.service.trim())
)

function toggleClearToken() {
  clearToken.value = !clearToken.value
  if (clearToken.value) form.mode = 'local'
}

function resetForm() {
  const c = configStore.config
  tokenInput.value = null
  clearToken.value = false
  if (!c) return
  form.mode = c.mode
  form.tunnel_name = c.tunnel_name
  form.routes = (c.routes || []).map((r: Route) => ({ ...r }))
  form.catch_all_service = c.catch_all_service
  form.post_quantum = c.post_quantum
  form.log_level = c.log_level
  form.no_tls_verify = c.no_tls_verify
  runParametersText.value = (c.run_parameters || []).join('\n')
}

function payload(): TunnelConfigUpdate {
  const body: TunnelConfigUpdate = {
    mode: form.mode,
    tunnel_name: form.tunnel_name.trim(),
    routes: form.routes.map((r) => ({ ...r, hostname: r.hostname.trim(), service: r.service.trim() })),
    catch_all_service: form.catch_all_service.trim(),
    post_quantum: form.post_quantum,
    log_level: form.log_level,
    run_parameters: runParameters.value,
    no_tls_verify: form.no_tls_verify,
  }
  // Omitted tunnel_token keeps the stored one; '' removes it.
  if (clearToken.value) body.tunnel_token = ''
  else if (tokenInput.value) body.tunnel_token = tokenInput.value
  return body
}

async function onSave(apply: boolean) {
  lastSaveApplied.value = apply
  const ok = await configStore.updateConfig(payload(), apply)
  if (apply) tunnelStore.fetchHealth()
  if (ok) {
    clearToken.value = false
    tokenInput.value = null
  }
}

watch(() => configStore.config, resetForm, { immediate: true })

onMounted(() => {
  configStore.fetchConfig()
})
</script>
