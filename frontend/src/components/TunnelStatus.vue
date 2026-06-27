<template>
  <StatusCard
    title="Tunnel Status"
    :badge="badge"
    :variant="statusVariant"
  >
    <div class="space-y-1.5 text-sm text-gray-700">
      <div v-if="status">
        {{ status.running ? 'Tunnel process is running' : 'Tunnel process is stopped' }}
      </div>
      <div v-else class="text-gray-400">
        Status unknown
      </div>
    </div>
  </StatusCard>
</template>

<script setup lang="ts">
import { computed } from 'vue'
import type { TunnelStatus } from '@/types'
import StatusCard from './StatusCard.vue'

const props = defineProps<{
  status: TunnelStatus | null
}>()

const badge = computed(() => {
  if (!props.status) return 'unknown'
  return props.status.running ? 'running' : 'stopped'
})

const statusVariant = computed(() => {
  if (props.status?.running) return 'green'
  return 'gray'
})
</script>
