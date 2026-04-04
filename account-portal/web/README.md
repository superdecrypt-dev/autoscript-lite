# Account Portal Web

Frontend React baru untuk migrasi penuh portal akun `autoscript`.

## Stack
- React
- Vite
- TypeScript
- Tailwind CSS v4
- shadcn/ui-style primitives
- Radix UI
- Recharts

## Commands
```bash
npm install
npm run dev
npm run typecheck
npm run build
```

## Target Route
- route utama React: `/account/:token`
- preview tetap tersedia: `/portal-react/account/:token`

## Source of Truth
Frontend ini memakai API backend portal yang sudah ada:
- `/api/account/:token/summary`
- `/api/account/:token/traffic`
- `/health`

## Notes
- Frontend React adalah UI utama portal akun yang live.
- Blueprint arsitektur final ada di [BLUEPRINT.md](./BLUEPRINT.md).
