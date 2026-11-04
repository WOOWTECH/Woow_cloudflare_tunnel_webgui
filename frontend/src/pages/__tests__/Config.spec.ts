import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import Config from '../Config.vue'
import type { TunnelConfig } from '@/types'

function baseConfig(overrides: Partial<TunnelConfig> = {}): TunnelConfig {
  return {
    mode: 'local', tunnel_name: '', routes: [], catch_all_service: '', post_quantum: false,
    log_level: 'info', run_parameters: [], no_tls_verify: true, tunnel_token_masked: '',
    tunnel_token_set: false, tunnel_token_managed_by_paas: false, ...overrides,
  }
}

function backend(config: TunnelConfig) {
  return vi.fn(async (url: string, init?: RequestInit) => {
    if (url === '/api/config') return { ok: true, json: async () => config }
    if (url.startsWith('/api/config?restart=')) return { ok: true, json: async () => ({ ...config, ...JSON.parse(String(init?.body)) }) }
    if (url === '/api/health') return { ok: true, json: async () => ({ status: 'ok', tunnel: { status: 'stopped' } }) }
    throw new Error(`unexpected fetch ${url}`)
  })
}

function mountConfig() {
  return mount(Config, { global: { plugins: [createPinia()], stubs: { RouterLink: { template: '<a><slot /></a>' } } } })
}

function lastPut(fetchMock: ReturnType<typeof backend>) {
  const call = fetchMock.mock.calls.find(([url]) => String(url).startsWith('/api/config?restart='))!
  return { url: String(call[0]), body: JSON.parse(String(call[1]!.body)) }
}

describe('Config', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    document.cookie = 'csrftoken=tok123'
  })
  afterEach(() => vi.unstubAllGlobals())

  it('sends run parameters as a list and Save & Apply as ?restart=true', async () => {
    const fetchMock = backend(baseConfig({ run_parameters: ['--protocol=http2'] }))
    vi.stubGlobal('fetch', fetchMock)
    const wrapper = mountConfig()
    await flushPromises()
    await wrapper.find('textarea').setValue('--protocol=http2\n\n--region=us')
    await wrapper.findAll('button').find((b) => b.text().includes('Save & Apply'))!.trigger('click')
    await flushPromises()
    const put = lastPut(fetchMock)
    expect(put.url).toBe('/api/config?restart=true')
    expect(put.body.run_parameters).toEqual(['--protocol=http2', '--region=us'])
    expect('tunnel_token' in put.body).toBe(false) // omitted = keep the stored token
  })

  it('blocks saving a run parameter outside the allow-list', async () => {
    vi.stubGlobal('fetch', backend(baseConfig()))
    const wrapper = mountConfig()
    await flushPromises()
    await wrapper.find('textarea').setValue('--token=abc')
    expect(wrapper.text()).toContain('不是允許的 run parameter')
    expect(wrapper.find('button[type="submit"]').attributes('disabled')).toBeDefined()
  })

  it('removing the token sends an empty string and switches to local', async () => {
    const fetchMock = backend(baseConfig({ mode: 'token', tunnel_token_set: true, tunnel_token_masked: '********' }))
    vi.stubGlobal('fetch', fetchMock)
    const wrapper = mountConfig()
    await flushPromises()
    await wrapper.findAll('button').find((b) => b.text().includes('移除 token'))!.trigger('click')
    await wrapper.find('form').trigger('submit')
    await flushPromises()
    const put = lastPut(fetchMock)
    expect(put.body.tunnel_token).toBe('')
    expect(put.body.mode).toBe('local')
  })

  it('a PaaS-managed token hides the token input and locks the mode', async () => {
    vi.stubGlobal('fetch', backend(baseConfig({ mode: 'token', tunnel_token_set: true, tunnel_token_managed_by_paas: true })))
    const wrapper = mountConfig()
    await flushPromises()
    expect(wrapper.text()).toContain('由 WOOW PaaS 自動管理')
    expect(wrapper.find('select').attributes('disabled')).toBeDefined()
  })
})
