export interface AdditionalHost {
  hostname: string
  service: string
  disableChunkedEncoding: boolean
}

/** A single ingress route used by the setup wizard / RouteEditor. */
export interface Route {
  hostname: string
  service: string
  disableChunkedEncoding: boolean
}

export type SetupMode = 'local' | 'token'

/** Shape of GET /api/setup/state. */
export interface SetupStateResponse {
  has_cert: boolean
  has_tunnel: boolean
  tunnel_uuid: string | null
  mode: SetupMode
}

export interface TunnelConfig {
  tunnel_token_secret: string
  tunnel_token_masked: string
  post_quantum: boolean
  log_level: 'trace' | 'debug' | 'info' | 'notice' | 'warn' | 'warning' | 'error' | 'fatal'
  extra_args: string
  container_name: string
  container_image: string
  external_hostname: string
  additional_hosts: AdditionalHost[]
  tunnel_name: string
  catch_all_service: string
  nginx_proxy_manager: boolean
}

export interface TunnelConfigUpdate {
  tunnel_token?: string | null
  post_quantum: boolean
  log_level: 'trace' | 'debug' | 'info' | 'notice' | 'warn' | 'warning' | 'error' | 'fatal'
  extra_args: string
  container_name: string
  container_image: string
  external_hostname: string
  additional_hosts: AdditionalHost[]
  tunnel_name: string
  catch_all_service: string
  nginx_proxy_manager: boolean
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
