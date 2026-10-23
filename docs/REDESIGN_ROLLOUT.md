# ECC CRM Redesign Rollout

This branch uses an additive UI override (`web/public/css/ecc-redesign.css`) for the first redesign phase. The override modernizes dashboard cards, pipeline presentation, tasks, activity, client workspace, tables, forms, notifications, responsive behavior, and dark mode without changing API contracts or existing Elm workflows.

## Production safety

- Existing Elm behavior remains unchanged.
- Existing CSS remains available underneath the override.
- Removing the final `ecc-redesign.css` link from `web/public/index.html` rolls the visual redesign back immediately.
- Functional workflow expansion (meetings, proposals, contracts, payments, invoices and richer client portal actions) should be introduced separately with API/schema support and tests rather than faked as visual-only controls.
