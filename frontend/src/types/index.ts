export type LogLevel =
  | 'trace'
  | 'debug'
  | 'info'
  | 'notice'
  | 'warn'
  | 'warning'
  | 'error'
  | 'fatal'

/** A single ingress route used by the setup wizard / RouteEditor / Config. */
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

/** Response model for GET/PUT /api/config (aligns with backend TunnelConfigRead). */
export interface TunnelConfig {
  mode: SetupMode
  tunnel_name: string
  routes: Route[]
  catch_all_service: string
  post_quantum: boolean
  log_level: LogLevel
  run_parameters: string
  no_tls_verify: boolean
  tunnel_token_masked: string
}

/** Request body for PUT /api/config (aligns with backend TunnelConfigWrite). */
export interface TunnelConfigUpdate {
  tunnel_token?: string | null
  mode: SetupMode
  tunnel_name: string
  routes: Route[]
  catch_all_service: string
  post_quantum: boolean
  log_level: LogLevel
  run_parameters: string
  no_tls_verify: boolean
}

/** Response model for GET /api/tunnel/status. */
export interface TunnelStatus {
  running: boolean
}

/** Response model for POST /api/tunnel/{start,stop,restart}. */
export interface ActionResponse {
  success: boolean
  message: string
}

/** Response model for GET /api/health. */
export interface HealthStatus {
  status: string
  process_running: boolean
}
