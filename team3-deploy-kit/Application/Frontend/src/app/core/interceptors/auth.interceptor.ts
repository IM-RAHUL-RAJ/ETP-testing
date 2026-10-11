import { HttpErrorResponse, HttpInterceptorFn, HttpRequest } from '@angular/common/http';
import { inject } from '@angular/core';
import { Router } from '@angular/router';
import { catchError, switchMap, throwError } from 'rxjs';
import { TokenService } from '../services/token.service';
import { AuthService } from '../services/auth.service';
import { environment } from '../../../environments/environment';

/**
 * Auth service routes that are `security: []` in auth-api.yaml and take no header.
 * Matched on the exact path, so a query string or a longer path that merely
 * contains one of these cannot switch the header off.
 */
const PUBLIC_AUTH_PATHS = new Set([
  '/auth/login',
  '/auth/register',
  '/auth/register/verify',
  '/auth/register/resend',
  '/auth/refresh',
  '/auth/logout',
]);

/**
 * Parses a request URL; null for anything that is not http(s). A relative URL
 * ("/api/v1/...", used when the APIs share the page's address behind one load
 * balancer) is resolved against the page's own origin.
 */
function parse(url: string): URL | null {
  try {
    const parsed = new URL(url, globalThis.location?.origin);
    return parsed.protocol === 'http:' || parsed.protocol === 'https:' ? parsed : null;
  } catch {
    return null;
  }
}

/**
 * True only when the request goes to one of our own platform APIs and to a route
 * that is protected there.
 *
 * The decision is an allow list compared on the exact origin (scheme, host and
 * port), never a prefix: 'http://localhost:3000.evil.com' and
 * 'http://localhost:30001' both start with 'http://localhost:3000' and are both
 * somebody else's host. Anything not on the list, including every third party
 * such as the market-data API, gets no token. An allow list fails closed.
 */
export function shouldAttachToken(url: string): boolean {
  const target = parse(url);
  if (!target) return false;
  if (!environment.platformOrigins.includes(target.origin)) return false;
  if (target.origin === new URL(environment.authApiUrl || '/', globalThis.location?.origin).origin) {
    return !PUBLIC_AUTH_PATHS.has(target.pathname);
  }
  return true;
}

function withBearer(req: HttpRequest<unknown>, token: string): HttpRequest<unknown> {
  return req.clone({ setHeaders: { Authorization: `Bearer ${token}` } });
}

/**
 * The only place in the application that sets an Authorization header.
 *
 * A 401 from a protected platform route means the 15-minute access token has
 * lapsed. The interceptor exchanges the HttpOnly refresh cookie for a new token
 * once and replays the request; if that fails too, the session is over and the
 * user is sent to sign in, carrying where they were.
 */
export const authInterceptor: HttpInterceptorFn = (req, next) => {
  if (!shouldAttachToken(req.url)) {
    return next(req);
  }

  const tokens = inject(TokenService);
  const auth = inject(AuthService);
  const router = inject(Router);

  const token = tokens.getAccessToken();
  const outgoing = token ? withBearer(req, token) : req;

  return next(outgoing).pipe(
    catchError((error: unknown) => {
      if (!(error instanceof HttpErrorResponse) || error.status !== 401 || !token) {
        return throwError(() => error);
      }
      return auth.refresh().pipe(
        switchMap((renewed) => {
          if (!renewed) {
            auth.expireSession(router.url);
            return throwError(() => error);
          }
          return next(withBearer(req, renewed));
        }),
      );
    }),
  );
};
