import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import RouteEditor from '../RouteEditor.vue'
import type { Route } from '@/types'

function makeRoute(overrides: Partial<Route> = {}): Route {
  return { hostname: '', service: '', disableChunkedEncoding: false, ...overrides }
}

describe('RouteEditor', () => {
  it('點「新增路由」會 emit update:routes 多一列', async () => {
    const wrapper = mount(RouteEditor, { props: { routes: [] } })
    await wrapper.get('[data-test="add-row"]').trigger('click')

    const emitted = wrapper.emitted('update:routes')
    expect(emitted).toBeTruthy()
    const payload = emitted![0][0] as Route[]
    expect(payload).toHaveLength(1)
    expect(payload[0]).toEqual({ hostname: '', service: '', disableChunkedEncoding: false })
  })

  it('點「刪除」會 emit 移除該列', async () => {
    const routes = [
      makeRoute({ hostname: 'a.example.com', service: 'http://x' }),
      makeRoute({ hostname: 'b.example.com', service: 'http://y' }),
    ]
    const wrapper = mount(RouteEditor, { props: { routes } })
    await wrapper.findAll('[data-test="remove-row"]')[0].trigger('click')

    const payload = wrapper.emitted('update:routes')![0][0] as Route[]
    expect(payload).toHaveLength(1)
    expect(payload[0].hostname).toBe('b.example.com')
  })

  it('合法 hostname 不顯示錯誤', () => {
    const routes = [makeRoute({ hostname: 'app.example.com', service: 'http://x' })]
    const wrapper = mount(RouteEditor, { props: { routes } })
    expect(wrapper.find('[data-test="hostname-error"]').exists()).toBe(false)
  })

  it('非法 hostname(含協定)顯示錯誤', () => {
    const routes = [makeRoute({ hostname: 'https://app.example.com', service: 'http://x' })]
    const wrapper = mount(RouteEditor, { props: { routes } })
    const err = wrapper.find('[data-test="hostname-error"]')
    expect(err.exists()).toBe(true)
    expect(err.text()).toContain('協定')
  })

  it('非法 hostname(含埠)顯示錯誤', () => {
    const routes = [makeRoute({ hostname: 'app.example.com:8123', service: 'http://x' })]
    const wrapper = mount(RouteEditor, { props: { routes } })
    expect(wrapper.find('[data-test="hostname-error"]').text()).toContain('埠')
  })

  it('輸入 hostname 會 emit update:routes 帶新值', async () => {
    const routes = [makeRoute({ service: 'http://x' })]
    const wrapper = mount(RouteEditor, { props: { routes } })
    const input = wrapper.get('input[type="text"]')
    await input.setValue('new.example.com')

    const payload = wrapper.emitted('update:routes')![0][0] as Route[]
    expect(payload[0].hostname).toBe('new.example.com')
  })
})
