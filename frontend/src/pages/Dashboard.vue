<template>
  <div class="space-y-6">
    <h1 class="text-2xl font-bold text-gray-900">Dashboard</h1>

    <!-- Status Cards -->
    <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
      <TunnelStatus :status="tunnelStore.status" />

      <StatusCard
        title="Mode"
        :badge="configStore.config?.mode ?? 'unknown'"
        :variant="configStore.config?.mode === 'token' ? 'green' : 'gray'"
      >
        <p class="text-sm text-gray-600">
          {{ modeDescription }}
        </p>
      </StatusCard>

      <StatusCard
        title="Token Status"
        :badge="configStore.config?.tunnel_token_masked ? 'configured' : 'missing'"
        :variant="configStore.config?.tunnel_token_masked ? 'green' : 'yellow'"
      >
        <p class="text-sm text-gray-600">
          {{ configStore.config?.tunnel_token_masked || 'No token configured' }}
        </p>
      </StatusCard>
    </div>

    <!-- Action Buttons -->
    <div class="flex gap-3">
      <button
        class="rounded-lg bg-green-600 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-green-700 disabled:opacity-50"
        :disabled="tunnelStore.actionLoading || isRunning"
        @click="tunnelStore.action('start')"
      >
        {{ tunnelStore.actionLoading ? 'Working...' : 'Start' }}
      </button>
      <button
        class="rounded-lg bg-red-600 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-red-700 disabled:opacity-50"
        :disabled="tunnelStore.actionLoading || !isRunning"
        @click="tunnelStore.action('stop')"
      >
        Stop
      </button>
      <button
        class="rounded-lg bg-amber-600 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-amber-700 disabled:opacity-50"
        :disabled="tunnelStore.actionLoading || !isRunning"
        @click="tunnelStore.action('restart')"
      >
        Restart
      </button>
    </div>

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

const isRunning = computed(() => tunnelStore.status?.running === true)

const modeDescription = computed(() => {
  const mode = configStore.config?.mode
  if (mode === 'token') return 'Token-based tunnel'
  if (mode === 'local') return 'Local (cert-based) tunnel'
  return 'Unknown mode'
})

onMounted(() => {
  tunnelStore.fetchStatus()
  configStore.fetchConfig()
})
</script>
