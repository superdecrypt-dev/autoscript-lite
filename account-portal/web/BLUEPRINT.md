# Account Portal Web Blueprint

## Stack Final
- React 19
- Vite 8
- TypeScript 5
- Tailwind CSS v4 via `@tailwindcss/vite`
- shadcn/ui-style component primitives
- Radix UI primitives
- Recharts for traffic chart
- Lucide React for icons

## Folder Layout
```text
web/
  components.json
  index.html
  package.json
  src/
    app/
      shell.tsx
    components/
      portal/
        access-card.tsx
        credentials-card.tsx
        hero-card.tsx
        import-links-card.tsx
        quota-card.tsx
        summary-card.tsx
        traffic-card.tsx
      providers/
        theme-provider.tsx
      theme/
        theme-menu.tsx
      ui/
        badge.tsx
        button.tsx
        card.tsx
        collapsible.tsx
        dropdown-menu.tsx
        separator.tsx
        tabs.tsx
        tooltip.tsx
    hooks/
      use-portal-data.ts
      use-theme.ts
    lib/
      api.ts
      portal.ts
      utils.ts
    routes/
      account-route.tsx
    types/
      portal.ts
    App.tsx
    index.css
    main.tsx
```

## Integration Target
- FastAPI remains the API/backend runtime.
- React app becomes the new UI layer for `/account/:token`.
- Existing API endpoints stay as the source of truth:
  - `/api/account/:token/summary`
  - `/api/account/:token/traffic`
  - `/health`

## Route Strategy
- React assets: `/account-app/assets/*`
- React main route: `/account/:token`
- React preview route: `/portal-react/account/:token`

## Migration Notes
- Phase 1: Build parity in `web/`.
- Phase 2: Serve static assets and React route from FastAPI/nginx.
- Phase 3: Remove remaining legacy server-rendered exposure and keep React as the single public UI.
