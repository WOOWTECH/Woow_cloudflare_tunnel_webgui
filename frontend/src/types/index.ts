/** cloudflared --loglevel values (cloudflared rejects anything else). */
export type LogLevel = 'debug' | 'info' | 'warn' | 'error' | 'fatal'

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
  run_parameters: string[]
  no_tls_verify: boolean
  tunnel_token_masked: string
  tunnel_token_set: boolean
  tunnel_token_managed_by_paas: boolean
}

/**
 * Request body for PUT /api/config (aligns with backend TunnelConfigWrite).
 * tunnel_token: undefined/null keeps the stored token, '' removes it, a value replaces it.
 */
export interface TunnelConfigUpdate {
  tunnel_token?: string | null
  mode: SetupMode
  tunnel_name: string
  routes: Route[]
  catch_all_service: string
  post_quantum: boolean
  log_level: LogLevel
  run_parameters: string[]
  no_tls_verify: boolean
}

/** Tunnel status from cloudflared's metrics /ready endpoint. */
export interface TunnelStatus {
  status: 'running' | 'starting' | 'stopped'
  ready_connections: number
  metrics_reachable: boolean
}

/** Response model for POST /api/tunnel/{start,stop,restart}. */
export interface ActionResponse {
  success: boolean
  message: string
}

/** Response model for GET /api/health. */
export interface HealthStatus {
  status: string
  version: string
  process_running: boolean
  stopped_by_operator: boolean
  tunnel: TunnelStatus
  credentials_error: string | null
}
