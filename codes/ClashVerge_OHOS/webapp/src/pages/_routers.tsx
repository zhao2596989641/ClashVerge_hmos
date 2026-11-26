import { createHashRouter, RouteObject } from 'react-router'

import Layout from './_layout'
import { navItems } from './_navigation'

// 鸿蒙侧由本地静态服务提供 index.html，使用 hash 路由避免刷新 404
export const router = createHashRouter([
  {
    path: '/',
    Component: Layout,
    children: navItems.map(
      (item) =>
        ({
          path: item.path,
          Component: item.Component,
        }) as RouteObject,
    ),
  },
])
