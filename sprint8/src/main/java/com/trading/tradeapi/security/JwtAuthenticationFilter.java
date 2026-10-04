package com.trading.tradeapi.security;

import io.jsonwebtoken.Claims;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.MediaType;
import org.springframework.http.HttpMethod;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.util.Set;

@Component
public class JwtAuthenticationFilter extends OncePerRequestFilter {

    public static final String AUTHENTICATED_ACCOUNT_ID_ATTR = "authenticatedAccountId";

    private final JwtService jwtService;
    private final Set<String> allowedOrigins;

    public JwtAuthenticationFilter(JwtService jwtService,
                                   @Value("${cors.allowed-origins}") String[] allowedOrigins) {
        this.jwtService = jwtService;
        this.allowedOrigins = Set.of(allowedOrigins);
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        String path = request.getRequestURI();
        // Allow CORS preflight requests through so the browser can negotiate CORS
        if (HttpMethod.OPTIONS.matches(request.getMethod())) {
            return true;
        }

        return !path.startsWith("/api/v1/");
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                    HttpServletResponse response,
                                    FilterChain filterChain) throws ServletException, IOException {
        String authHeader = request.getHeader("Authorization");

        if (authHeader == null || !authHeader.startsWith("Bearer ")) {
            sendUnauthorized(request, response);
            return;
        }

        String token = authHeader.substring(7).trim();
        try {
            Claims claims = jwtService.validateAndParseToken(token);
            Long accountId = jwtService.extractAccountId(claims);
            if (accountId == null) {
                sendUnauthorized(request, response);
                return;
            }
            request.setAttribute(AUTHENTICATED_ACCOUNT_ID_ATTR, accountId);
            filterChain.doFilter(request, response);
        } catch (Exception e) {
            sendUnauthorized(request, response);
        }
    }

    private void sendUnauthorized(HttpServletRequest request, HttpServletResponse response) throws IOException {
        // Add CORS headers to error responses so browser can see the error message
        String origin = request.getHeader("Origin");
        if (origin != null && allowedOrigins.contains(origin)) {
            response.setHeader("Access-Control-Allow-Origin", origin);
            response.setHeader("Vary", "Origin");
            response.setHeader("Access-Control-Allow-Credentials", "true");
            response.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS, PATCH");
            response.setHeader("Access-Control-Allow-Headers", "*");
            response.setHeader("Access-Control-Expose-Headers", "Content-Type, Authorization");
        }

        response.setStatus(HttpServletResponse.SC_UNAUTHORIZED);
        response.setContentType(MediaType.APPLICATION_JSON_VALUE);
        response.getWriter().write("{\"errorCode\":\"AUTH-401\",\"message\":\"Unauthorised\"}");
    }
}
