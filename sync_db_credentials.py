"""
Sincroniza las credenciales de los servidores de base de datos con backend/.env.

Para cada instancia de servidores.ini busca el target con el mismo nombre y:
  - si su credencial no existe (p. ej. se borró SNT_CREDENTIALS), crea una nueva
    y la enlaza;
  - si existe, actualiza usuario, contraseña, puerto, base y servicio con lo que
    hoy dicen el .ini y las variables DB_USER_<AMBIENTE>_<MOTOR> / DB_PASSWORD_...

Uso (desde backend):
  .venv\\Scripts\\python.exe -m app.db.sync_db_credentials            # aplica
  .venv\\Scripts\\python.exe -m app.db.sync_db_credentials --dry-run  # solo muestra
  .venv\\Scripts\\python.exe -m app.db.sync_db_credentials --ini otra_ruta.ini
"""

from __future__ import annotations

import argparse
import asyncio
import sys
from dataclasses import dataclass, field
from pathlib import Path

from sqlalchemy import select

from app.core.security import encrypt
from app.db.migrate_to_oracle import BACKEND_DIR

DEFAULT_INI = BACKEND_DIR / "servidores.ini"


@dataclass
class SyncReport:
    created: int = 0
    updated: int = 0
    without_user: list[str] = field(default_factory=list)
    not_found: list[str] = field(default_factory=list)


def _apply(cred, spec: dict) -> None:
    cred.label = spec["label"]
    cred.conn_method = spec["conn_method"]
    cred.username = spec["username"] or None
    cred.password_enc = encrypt(spec["password"]) if spec["password"] else None
    cred.db_type = spec["db_type"]
    cred.db_port = spec["db_port"]
    cred.db_name = spec["db_name"]
    cred.db_service = spec["db_service"]


async def sync(ini_path: Path, dry_run: bool) -> SyncReport:
    sys.path.insert(0, str(BACKEND_DIR))
    import load_targets_from_ini as ini   # carga backend/.env (DB_USER_*, DB_PASSWORD_*)
    from app.db.session import AsyncSessionLocal, init_db
    from app.models.models import Credential, Target

    await init_db()   # recrea SNT_CREDENTIALS si falta
    report = SyncReport()
    async with AsyncSessionLocal() as session:
        targets = {t.name: t for t in (await session.execute(
            select(Target).where(Target.target_type == "database"))).scalars()}
        existing_ids = set((await session.execute(select(Credential.id))).scalars())

        seen: set[str] = set()
        for env, engine, entry in ini.parse_ini_file(str(ini_path)):
            payload = ini.build_payload(entry, env, engine, None, None, 300)
            name = payload["name"]
            if name in seen:
                continue
            seen.add(name)
            target = targets.get(name)
            if target is None:
                report.not_found.append(name)
                continue
            spec = payload["credential"]
            if not spec["username"]:
                report.without_user.append(f"{name} ({env}/{engine})")

            if target.credential_id in existing_ids:
                cred = await session.get(Credential, target.credential_id)
                _apply(cred, spec)
                report.updated += 1
            else:
                cred = Credential()
                _apply(cred, spec)
                session.add(cred)
                await session.flush()
                target.credential_id = cred.id
                report.created += 1
            # Sin credencial válida el último error ya no aplica: se vuelve a sondear.
            target.status, target.last_error = "unknown", None

        if dry_run:
            await session.rollback()
        else:
            await session.commit()
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Sincroniza credenciales de BD desde servidores.ini y .env")
    parser.add_argument("--ini", default=str(DEFAULT_INI), help="Ruta de servidores.ini")
    parser.add_argument("--dry-run", action="store_true", help="Muestra qué haría sin guardar")
    args = parser.parse_args(argv)

    ini_path = Path(args.ini)
    if not ini_path.is_file():
        print(f"No existe {ini_path}")
        return 1
    report = asyncio.run(sync(ini_path, args.dry_run))
    prefix = "[SIMULACIÓN] " if args.dry_run else ""
    print(f"{prefix}Credenciales creadas y enlazadas: {report.created}")
    print(f"{prefix}Credenciales actualizadas: {report.updated}")
    if report.without_user:
        print(f"Sin usuario en .env ({len(report.without_user)}): defina DB_USER_<AMBIENTE>_<MOTOR> y DB_PASSWORD_...")
        for item in report.without_user[:15]:
            print("   -", item)
    if report.not_found:
        print(f"En el .ini pero no en la base ({len(report.not_found)}): use el botón 'Importar servidores.ini'")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
