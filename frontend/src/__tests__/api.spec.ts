import { describe, it, expect, vi, afterEach } from 'vitest'
import { api } from '../api'

describe('api()', () => {
  afterEach(() => vi.unstubAllGlobals())

  it('sends the CSRF header on state-changing requests only', async () => {
    document.cookie = 'csrftoken=tok123'
    const fetchMock = vi.fn(async () => ({ ok: true, json: async () => ({}) }))
    vi.stubGlobal('fetch', fetchMock)
    await api('/api/config')
    await api('/api/tunnel/start', { method: 'POST' })
    const calls = fetchMock.mock.calls as unknown as [string, RequestInit][]
    expect((calls[0][1].headers as Record<string, string>)['x-csrftoken']).toBeUndefined()
    expect((calls[1][1].headers as Record<string, string>)['x-csrftoken']).toBe('tok123')
  })

  it('turns a FastAPI 422 detail list into field: message', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => ({
      ok: false,
      status: 422,
      json: async () => ({ detail: [{ loc: ['body', 'tunnel_token'], msg: 'bad token', type: 'value_error' }] }),
    })))
    await expect(api('/api/config', { method: 'PUT' })).rejects.toThrow('tunnel_token: bad token')
  })

  it('passes a string detail through', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: false, status: 409, json: async () => ({ detail: '先解除綁定' }) })))
    await expect(api('/api/config', { method: 'PUT' })).rejects.toThrow('先解除綁定')
  })
})
