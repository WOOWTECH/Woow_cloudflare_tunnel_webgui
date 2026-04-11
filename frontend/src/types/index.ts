export interface TunnelConfig {
  tunnel_token_secret: string
  tunnel_token_masked: string
  post_quantum: boolean
  log_level: 'debug' | 'info' | 'warn' | 'error' | 'fatal'
  extra_args: string
  container_name: string
  container_image: string
}

export interface TunnelConfigUpdate {
  tunnel_token?: string | null
  post_quantum: boolean
  log_level: 'debug' | 'info' | 'warn' | 'error' | 'fatal'
  extra_args: string
  container_name: string
  container_image: string
}

export type ContainerStatusType =
  | 'running'
  | 'stopped'
  | 'exited'
  | 'created'
  | 'paused'
  | 'restarting'
  | 'removing'
  | 'dead'
  | 'not_found'
  | 'unknown'

export interface TunnelStatus {
  status: ContainerStatusType
  container_id: string | null
  image: string | null
  started_at: string | null
  uptime_seconds: number | null
  restart_count: number
  exit_code: number | null
}

export interface ActionResponse {
  success: boolean
  message: string
  container_id?: string
}

export interface HealthStatus {
  status: string
  podman_connected: boolean
  tunnel_status: ContainerStatusType
}
