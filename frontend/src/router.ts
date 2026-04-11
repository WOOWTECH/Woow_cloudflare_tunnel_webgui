import { createRouter, createWebHistory } from 'vue-router'
import Dashboard from '@/pages/Dashboard.vue'
import Config from '@/pages/Config.vue'
import Logs from '@/pages/Logs.vue'

const routes = [
  { path: '/', name: 'dashboard', component: Dashboard },
  { path: '/config', name: 'config', component: Config },
  { path: '/logs', name: 'logs', component: Logs },
]

export default createRouter({
  history: createWebHistory(),
  routes,
})
