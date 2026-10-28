## Future Supabase And Render Setup

This document is a preparation checklist only. No cloud project, service, image, or deployment has been created or contacted.

The backend uses PostgreSQL directly and is compatible with PostgreSQL deployments. Before provisioning cloud services:

1. Review the canonical local backend under `my_server/` and validate it with `npm test` and the opt-in local PostgreSQL integration tests.
2. Create a production database only when explicitly ready. Configure `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`, and `DB_SSL=true` from that provider's private connection settings. Never copy local credentials into production.
3. Configure a unique random `API_SECRET_KEY` and a separate random `PASSWORD_RESET_OTP_SECRET` of at least 32 characters.
4. Configure a real HTTPS email provider and Twilio (or another implemented provider) before advertising recovery delivery. Set `LOCAL_MOCK_DELIVERY=false`; the mock adapter only works in development.
5. Set `PUBLIC_BASE_URL` to the final HTTPS API origin. Do not use a sample hostname or a local address.
6. Provision each caretaker through a trusted production-only process with a unique, fresh password and a verified individual recovery contact. The local caretaker seed deliberately refuses non-local databases and must not be used for production.
7. Update the Flutter release `API_BASE_URL` to the final HTTPS API origin and test Android release networking.
8. Review `.gitignore`, `git status`, secret scanning, and all untracked source before staging. Never commit `.env`, signing keys, database exports, or temporary caretaker passwords.
9. Only after those checks should CI/deployment be configured. No push or deployment is performed by this repository setup.

`render.yaml` and `.env.render.example` are templates, not active services. Render should use the repository root, `npm ci --omit=dev`, and `npm start`. The Docker image is built locally with `docker build -f Dockerfile .` and uses the same canonical server entry point.
