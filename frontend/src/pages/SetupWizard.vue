<template>
  <div class="mx-auto flex max-w-3xl flex-col gap-6 py-4">
    <h1 class="text-2xl font-bold text-gray-900">上線精靈</h1>

    <!-- Step indicator -->
    <ol class="flex items-center gap-2 text-xs font-medium text-gray-400">
      <li :class="step === 'A' ? 'text-cf-orange' : ''">1. 連結帳號</li>
      <li>›</li>
      <li :class="step === 'B' ? 'text-cf-orange' : ''">2. 建立 Tunnel</li>
      <li>›</li>
      <li :class="step === 'C' ? 'text-cf-orange' : ''">3. 設定路由</li>
      <li>›</li>
      <li :class="step === 'D' ? 'text-cf-orange' : ''">4. 運作中</li>
    </ol>

    <!-- Step A: link Cloudflare account -->
    <section
      v-if="step === 'A'"
      data-test="step-a"
      class="rounded-xl border border-gray-200 bg-white p-6 shadow-sm"
    >
      <h2 class="mb-2 text-lg font-semibold text-gray-900">連結 Cloudflare 帳號</h2>
      <p class="mb-4 text-sm text-gray-500">
        點擊下方按鈕產生授權連結,於瀏覽器登入並授權後,系統會自動偵測憑證。
      </p>
      <button
        type="button"
        class="rounded-lg bg-cf-orange px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-orange-600 disabled:opacity-50"
        data-test="start-login"
        :disabled="loginConnecting"
        @click="startLogin"
      >
        {{ loginConnecting ? '產生連結中…' : '連結 Cloudflare 帳號' }}
      </button>

      <div v-if="loginUrl" class="mt-4 rounded-lg border border-blue-200 bg-blue-50 p-4">
        <p class="mb-1 text-sm text-gray-700">請於瀏覽器開啟下列連結完成授權:</p>
        <a
          :href="loginUrl"
          target="_blank"
          rel="noopener noreferrer"
          class="break-all text-sm font-medium text-blue-600 underline"
          data-test="login-url"
        >
          {{ loginUrl }}
        </a>
        <p v-if="polling" class="mt-2 text-xs text-gray-500">等待授權完成中…</p>
      </div>
    </section>

    <!-- Step B: create tunnel -->
    <section
      v-else-if="step === 'B'"
      data-test="step-b"
      class="rounded-xl border border-gray-200 bg-white p-6 shadow-sm"
    >
      <h2 class="mb-2 text-lg font-semibold text-gray-900">建立 Tunnel</h2>
      <p class="mb-4 text-sm text-gray-500">為這個 tunnel 取一個名稱。</p>
      <div class="flex gap-2">
        <input
          v-model="tunnelName"
          type="text"
          placeholder="my-home-tunnel"
          class="flex-1 rounded-lg border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-cf-orange focus:outline-none focus:ring-1 focus:ring-cf-orange"
          data-test="tunnel-name"
        />
        <button
          type="button"
          class="rounded-lg bg-cf-orange px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-orange-600 disabled:opacity-50"
          data-test="create-tunnel"
          :disabled="!tunnelName.trim() || setup.loading"
          @click="onCreateTunnel"
        >
          建立
        </button>
      </div>
    </section>

    <!-- Step C: routes + apply -->
    <section
      v-else-if="step === 'C'"
      data-test="step-c"
      class="flex flex-col gap-4"
    >
      <div class="rounded-xl border border-gray-200 bg-white p-6 shadow-sm">
        <h2 class="mb-2 text-lg font-semibold text-gray-900">設定路由</h2>
        <p class="mb-4 text-sm text-gray-500">
          新增要透過 tunnel 對外公開的服務。Tunnel UUID:
          <code class="text-gray-700">{{ setup.tunnelUuid }}</code>
        </p>
        <RouteEditor v-model:routes="routes" />

        <div class="mt-4">
          <label class="mb-1 block text-xs font-medium text-gray-500">
            Catch-all service(選填)
          </label>
          <input
            v-model="catchAll"
            type="text"
            placeholder="http_status:404"
            class="w-full rounded-lg border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-cf-orange focus:outline-none focus:ring-1 focus:ring-cf-orange"
            data-test="catch-all"
          />
        </div>
      </div>

      <div
        v-if="setup.error"
        class="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700"
        data-test="apply-error"
      >
        {{ setup.error }}
      </div>

      <div>
        <button
          type="button"
          class="rounded-lg bg-cf-orange px-5 py-2 text-sm font-medium text-white shadow-sm hover:bg-orange-600 disabled:opacity-50"
          data-test="apply"
          :disabled="!canApply"
          @click="onApply"
        >
          {{ setup.loading ? '套用中…' : '套用並啟動' }}
        </button>
      </div>
    </section>

    <!-- Step D: running -->
    <section
      v-else
      data-test="step-d"
      class="flex flex-col gap-4"
    >
      <div class="rounded-xl border border-green-200 bg-green-50 p-6 shadow-sm">
        <h2 class="mb-1 text-lg font-semibold text-green-800">Tunnel 運作中</h2>
        <p class="text-sm text-green-700">
          設定已套用,cloudflared 已啟動。Tunnel UUID:
          <code>{{ setup.tunnelUuid }}</code>
        </p>
      </div>
      <div class="h-[420px]">
        <LogViewer :messages="messages" :connected="connected" @clear="clear" />
      </div>
    </section>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import { useSetupStore } from '@/stores/setup'
import { useWebSocket } from '@/composables/useWebSocket'
import { hostnameError } from '@/utils/hostname'
import RouteEditor from '@/components/RouteEditor.vue'
import LogViewer from '@/components/LogViewer.vue'
import type { Route } from '@/types'

type WizardStep = 'A' | 'B' | 'C' | 'D'

interface LoginMessage {
  type: string
  url?: string
}

const setup = useSetupStore()

const tunnelName = ref('')
const routes = ref<Route[]>([])
const catchAll = ref('')
const appliedDone = ref(false)

// --- Step A: account-link via WebSocket ---
const loginUrl = ref<string | null>(null)
const loginConnecting = ref(false)
const polling = ref(false)
let loginWs: WebSocket | null = null
let pollTimer: ReturnType<typeof setInterval> | null = null

const step = computed<WizardStep>(() => {
  if (!setup.hasCert) return 'A'
  if (!setup.hasTunnel) return 'B'
  if (appliedDone.value) return 'D'
  return 'C'
})

const canApply = computed<boolean>(
  () =>
    routes.value.length > 0 &&
    routes.value.every((r) => hostnameError(r.hostname) === null) &&
    !setup.loading
)

// --- Logs (step D) ---
const { messages, connected, connect, clear } = useWebSocket('/ws/logs')

function startPolling(): void {
  if (polling.value) return
  polling.value = true
  pollTimer = setInterval(() => {
    void setup.fetchState().then(() => {
      if (setup.hasCert) stopPolling()
    })
  }, 3000)
}

function stopPolling(): void {
  polling.value = false
  if (pollTimer) {
    clearInterval(pollTimer)
    pollTimer = null
  }
}

function startLogin(): void {
  loginUrl.value = null
  loginConnecting.value = true
  const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
  loginWs = new WebSocket(`${protocol}//${window.location.host}/api/setup/login`)

  loginWs.onmessage = (event: MessageEvent) => {
    const msg = JSON.parse(event.data as string) as LoginMessage
    if (msg.type === 'url' && msg.url) {
      loginUrl.value = msg.url
      loginConnecting.value = false
      startPolling()
    } else if (msg.type === 'done') {
      stopPolling()
      void setup.fetchState()
    }
  }
  loginWs.onerror = () => {
    loginConnecting.value = false
  }
  loginWs.onclose = () => {
    loginConnecting.value = false
  }
}

async function onCreateTunnel(): Promise<void> {
  const name = tunnelName.value.trim()
  if (!name) return
  await setup.createTunnel(name)
}

async function onApply(): Promise<void> {
  const ok = await setup.apply(routes.value, catchAll.value)
  if (ok) appliedDone.value = true
}

watch(step, (s) => {
  if (s === 'D') connect()
})

onMounted(() => {
  void setup.fetchState()
})

onUnmounted(() => {
  stopPolling()
  if (loginWs) {
    loginWs.close()
    loginWs = null
  }
})
</script>
