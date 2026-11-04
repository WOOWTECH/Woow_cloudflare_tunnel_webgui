<template>
  <div class="space-y-6">
    <h1 class="text-2xl font-bold text-gray-900">Dashboard</h1>

    <!-- Credential files that could not be made private -->
    <div
      v-if="health?.credentials_error"
      class="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700"
    >
      <span class="font-medium">憑證檔權限檢查失敗,tunnel 不會啟動:</span>
      {{ health.credentials_error }}。請把它換成一般檔案(不能是 symlink 或 hardlink)後再按 Start。
    </div>

    <!-- Stopped from this GUI -->
    <div
      v-else-if="health?.stopped_by_operator"
      class="rounded-lg border border-gray-200 bg-gray-50 px-4 py-3 text-sm text-gray-700"
    >
      偵測到 <code>/data/.tunnel_stopped</code> 標記:healthcheck 與開機自動啟動都不會把 tunnel 拉起。
      按 Start 會移除標記並啟動。
    </div>

    <!-- First run -->
    <div
      v-else-if="unconfigured"
      class="rounded-lg border border-blue-200 bg-blue-50 px-4 py-3 text-sm text-blue-700"
    >
      <span class="font-medium">尚未設定 tunnel。</span>
      使用 WOOW PaaS 訂閱請到
      <router-link to="/paas" class="font-medium underline">PaaS 連結</router-link>;
      自行管理 Cloudflare 請到
      <router-link to="/setup" class="font-medium underline">Setup</router-link>,
      或在 <router-link to="/config" class="font-medium underline">Config</router-link> 貼上 tunnel token。
    </div>

    <!-- Status Cards -->
    <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
      <TunnelStatus
        :tunnel="health?.tunnel ?? null"
        :stopped-by-operator="health?.stopped_by_operator"
      />

      <StatusCard
        title="Mode"
        :badge="config?.mode ?? 'unknown'"
        :variant="config?.mode === 'token' ? 'green' : 'gray'"
      >
        <p class="text-sm text-gray-600">{{ modeDescription }}</p>
      </StatusCard>

      <StatusCard
        title="Token"
        :badge="tokenBadge"
        :variant="config?.tunnel_token_set ? 'green' : config?.mode === 'token' ? 'yellow' : 'gray'"
      >
        <p class="text-sm text-gray-600">
          {{ tokenDescription }}
        </p>
        <p v-if="health?.version" class="mt-1 text-xs text-gray-400">Version {{ health.version }}</p>
      </StatusCard>
    </div>

    <!-- Action Buttons -->
    <div class="flex gap-3">
      <button
        class="rounded-lg bg-green-600 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-green-700 disabled:opacity-50"
        :disabled="tunnelStore.actionLoading || tunnelStore.isRunning"
        @click="run('start')"
      >
        {{ tunnelStore.actionLoading ? 'Working...' : 'Start' }}
      </button>
      <button
        class="rounded-lg bg-red-600 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-red-700 disabled:opacity-50"
        :disabled="tunnelStore.actionLoading || !tunnelStore.isRunning"
        @click="onStop"
      >
        Stop
      </button>
      <button
        class="rounded-lg bg-amber-600 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-amber-700 disabled:opacity-50"
        :disabled="tunnelStore.actionLoading || !tunnelStore.isRunning"
        @click="run('restart')"
      >
        Restart
      </button>
    </div>
    <p class="text-xs text-gray-400">
      Start 與 Restart 都會以目前儲存的設定重新啟動 cloudflared(local 模式會重新產生並驗證 ingress)。
    </p>

    <!-- Error display -->
    <div
      v-if="tunnelStore.error"
      class="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700"
    >
      {{ tunnelStore.error }}
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted } from 'vue'
import { useTunnelStore } from '@/stores/tunnel'
import { useConfigStore } from '@/stores/config'
import TunnelStatus from '@/components/TunnelStatus.vue'
import StatusCard from '@/components/StatusCard.vue'

const tunnelStore = useTunnelStore()
const configStore = useConfigStore()

const health = computed(() => tunnelStore.health)
const config = computed(() => configStore.config)

const unconfigured = computed(() => {
  const c = config.value
  if (!c || tunnelStore.isRunning) return false
  return c.mode === 'token' ? !c.tunnel_token_set : c.routes.length === 0 && !c.catch_all_service
})

const modeDescription = computed(() => {
  const mode = config.value?.mode
  if (mode === 'token') return 'Remote-managed tunnel:路由在 Cloudflare 後台或 PaaS 管理'
  if (mode === 'local') return 'Local-managed tunnel (cert.pem):路由由此介面管理'
  if (configStore.error) return `無法讀取設定:${configStore.error}`
  return 'Loading...'
})

const tokenBadge = computed(() => {
  if (config.value?.tunnel_token_managed_by_paas) return 'PaaS'
  return config.value?.tunnel_token_set ? 'configured' : 'missing'
})

const tokenDescription = computed(() => {
  if (config.value?.tunnel_token_managed_by_paas) return '由 WOOW PaaS 自動管理'
  if (config.value?.tunnel_token_set) return config.value.tunnel_token_masked
  return config.value?.mode === 'token' ? 'token 模式尚未設定 token' : 'local 模式不需要 token'
})

async function run(endpoint: 'start' | 'restart') {
  await tunnelStore.action(endpoint).catch(() => {})
}

async function onStop() {
  const ok = window.confirm(
    '停止 tunnel?已設定的 tunnel 約 2 分鐘後會被 healthcheck 自動拉回;在這段期間,經由這條 tunnel 的 SSH 等連線都會中斷。'
  )
  if (ok) await tunnelStore.action('stop').catch(() => {})
}

onMounted(() => {
  tunnelStore.fetchHealth()
  configStore.fetchConfig()
})
</script>
