Front-end test UI for the Spring Boot trading backend

This simple front end uses Python Flask to serve two pages: `/login` and `/dashboard`.
It was generated from the contents of `frontEndPrompt.txt` and wired to use the backend URLs via environment variables.

Files created
- [front-end/app.py](front-end/app.py)
- [front-end/templates/login.html](front-end/templates/login.html)
- [front-end/templates/dashboard.html](front-end/templates/dashboard.html)
- [front-end/static/js/app.js](front-end/static/js/app.js)
- [front-end/static/css/style.css](front-end/static/css/style.css)
- [front-end/.env.example](front-end/.env.example)
- [front-end/requirements.txt](front-end/requirements.txt)

Configuration
- Copy `.env.example` to `.env` and edit `BACKEND_URL` and `AUTH_URL` if your services run on different ports.
  - Default `BACKEND_URL` is `http://localhost:8082` (Spring Boot)
  - Default `AUTH_URL` is `http://localhost:3000` (Auth server)
  - The auth server expects `POST /api/auth` for login and `GET /api/auth/verify` for token verification.

Run locally (recommended in a virtualenv)

```bash
python -m venv .venv
source .venv/Scripts/activate   # Windows: .venv\Scripts\activate
pip install -r front-end/requirements.txt
# copy .env.example -> .env and edit if needed
python front-end/app.py
```

Usage
- Open `http://localhost:4200/login` in your browser.
- Log in using the auth server credentials; the JS expects the response to include a JWT (field `token` or `accessToken`).
- After login you'll be redirected to `/dashboard` and can call profile, holdings, orders, and place order.

Notes
- The front end expects the backend to allow CORS from `http://localhost:4200`. If you get CORS issues, enable CORS in the Spring Boot app or run the front end as a static file served by a web server.
