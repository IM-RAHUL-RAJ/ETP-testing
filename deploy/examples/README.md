# Examples

A real configuration, used to start the full stack with this folder: the images
build, the SQL loads, and the services answer through the frontend container.
Copy its `project.yaml` and `application.yaml` into `deploy/config/` and change
the paths.

| Folder | Shape | Shows |
|---|---|---|
| `spring-nestjs-smtp/` | Spring Boot order and executor services, NestJS auth, Angular page; migrations and seed folders loaded by the kit | `sql:` as folders, `proxy: true` with route prefixes, mail sent straight through SMTP (`mail:` host and port, login typed into `.env`), `derived_secrets` |

What to check in your own project:

- the page uses relative or same-origin addresses (no `localhost` compiled in);
- every Spring placeholder without a default has a setting in `project.yaml`
  (`${a.b}` is read from the environment variable `A_B`);
- the database is created by the kit's SQL or by the service's own migrations,
  not by a file outside the repository.

More examples (a Flyway/Liquibase project, a project whose auth routes carry a
prefix) will be added once each has been run with this folder.
