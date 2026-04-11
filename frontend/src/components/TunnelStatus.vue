<template>
  <StatusCard
    title="Tunnel Status"
    :badge="status?.status ?? 'unknown'"
    :variant="statusVariant"
  >
    <div class="space-y-1.5 text-sm text-gray-700">
      <div v-if="status?.container_id">
        <span class="font-medium">Container:</span>
        {{ status.container_id.slice(0, 12) }}
      </div>
      <div v-if="status?.image">
        <span class="font-medium">Image:</span>
        {{ status.image }}
      </div>
      <div v-if="status?.started_at && status.status === 'running'">
        <span class="font-medium">Started:</span>
        {{ formatDate(status.started_at) }}
      </div>
      <div v-if="status?.exit_code !== null && status?.exit_code !== undefined && status.status !== 'running'">
        <span class="font-medium">Exit Code:</span>
        {{ status.exit_code }}
      </div>
      <div v-if="!status || status.status === 'not_found'" class="text-gray-400">
        No container found
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

const statusVariant = computed(() => {
  const s = props.status?.status
  if (s === 'running') return 'green'
  if (s === 'exited' || s === 'stopped') return 'red'
  if (s === 'created') return 'yellow'
  return 'gray'
})

function formatDate(iso: string): string {
  try {
    return new Date(iso).toLocaleString()
  } catch {
    return iso
  }
}
</script>
