#!/usr/bin/env python3
"""Busca comércios locais na Google Places API (New) e salva os leads em CSV.

Uso:
    export GOOGLE_PLACES_API_KEY="sua-chave"
    python buscar_leads.py "padaria em Eldorado, Contagem"

Sem o termo na linha de comando, o script pergunta. Rode com --help para ver
as opções.
"""

from __future__ import annotations

import argparse
import csv
import logging
import os
import sys
import time
from dataclasses import asdict, dataclass, fields
from pathlib import Path

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

API_URL = "https://places.googleapis.com/v1/places:searchText"
API_KEY_ENV = "GOOGLE_PLACES_API_KEY"
DEFAULT_OUTPUT = "leads_locais.csv"

# A Text Search devolve no máximo 20 resultados por página e 60 no total.
PAGE_SIZE = 20
MAX_RESULTS = 60
TIMEOUT = (5, 30)  # (conexão, leitura) em segundos

# Só os campos pedidos aqui são cobrados e retornados pela API.
FIELD_MASK = ",".join(
    [
        "places.displayName",
        "places.nationalPhoneNumber",
        "places.internationalPhoneNumber",
        "places.formattedAddress",
        "places.websiteUri",
        "places.rating",
        "nextPageToken",
    ]
)

log = logging.getLogger("buscar_leads")


class PlacesAPIError(Exception):
    """Falha ao consultar a Places API."""


@dataclass
class Lead:
    nome: str
    telefone: str
    endereco: str
    website: str
    nota: str

    @classmethod
    def from_place(cls, place: dict) -> "Lead":
        rating = place.get("rating")
        return cls(
            nome=place.get("displayName", {}).get("text", ""),
            telefone=place.get("nationalPhoneNumber")
            or place.get("internationalPhoneNumber", ""),
            endereco=place.get("formattedAddress", ""),
            website=place.get("websiteUri", ""),
            nota=f"{rating:.1f}" if isinstance(rating, (int, float)) else "",
        )


CSV_HEADERS = {
    "nome": "Nome",
    "telefone": "Telefone",
    "endereco": "Endereço",
    "website": "Website",
    "nota": "Nota",
}


def build_session(api_key: str) -> requests.Session:
    """Sessão com cabeçalhos da API e novas tentativas para erros temporários."""
    retry = Retry(
        total=3,
        backoff_factor=1,  # espera 1 s, 2 s, 4 s
        status_forcelist=(429, 500, 502, 503, 504),
        allowed_methods=frozenset({"POST"}),
        raise_on_status=False,
    )
    session = requests.Session()
    session.mount("https://", HTTPAdapter(max_retries=retry))
    session.headers.update(
        {
            "Content-Type": "application/json",
            "X-Goog-Api-Key": api_key,
            "X-Goog-FieldMask": FIELD_MASK,
        }
    )
    return session


def _error_message(response: requests.Response) -> str:
    """Extrai a mensagem de erro do corpo JSON da Google, se houver."""
    try:
        error = response.json().get("error", {})
        return f"{error.get('status', '')} {error.get('message', '')}".strip()
    except ValueError:
        return response.text[:300]


def search_places(
    session: requests.Session,
    query: str,
    max_results: int = MAX_RESULTS,
    language: str = "pt-BR",
    region: str = "BR",
) -> list[dict]:
    """Faz a Text Search seguindo a paginação até max_results lugares."""
    places: list[dict] = []
    page_token: str | None = None

    while len(places) < max_results:
        body = {
            "textQuery": query,
            "languageCode": language,
            "regionCode": region,
            # As páginas seguintes precisam repetir os mesmos parâmetros.
            "pageSize": min(PAGE_SIZE, max_results),
        }
        if page_token:
            body["pageToken"] = page_token

        try:
            response = session.post(API_URL, json=body, timeout=TIMEOUT)
        except requests.exceptions.Timeout as exc:
            raise PlacesAPIError("A API demorou demais para responder.") from exc
        except requests.exceptions.ConnectionError as exc:
            raise PlacesAPIError(
                "Não foi possível conectar à API. Verifique a internet."
            ) from exc
        except requests.exceptions.RequestException as exc:
            raise PlacesAPIError(f"Erro na requisição: {exc}") from exc

        if response.status_code in (401, 403):
            raise PlacesAPIError(
                "Acesso negado. Confira se a chave é válida e se a "
                f"'Places API (New)' está ativada no projeto. ({_error_message(response)})"
            )
        if not response.ok:
            raise PlacesAPIError(
                f"HTTP {response.status_code}: {_error_message(response)}"
            )

        try:
            data = response.json()
        except ValueError as exc:
            raise PlacesAPIError("A API devolveu uma resposta inválida.") from exc

        page = data.get("places", [])
        places.extend(page)
        log.info("Página com %d resultado(s); total %d.", len(page), len(places))

        page_token = data.get("nextPageToken")
        if not page_token or not page:
            break
        time.sleep(0.5)  # pequena pausa entre páginas

    return places[:max_results]


def save_csv(leads: list[Lead], path: Path, delimiter: str = ";") -> None:
    """Grava os leads em CSV (UTF-8 com BOM, para o Excel abrir com acentos)."""
    names = [f.name for f in fields(Lead)]
    with path.open("w", newline="", encoding="utf-8-sig") as fh:
        writer = csv.DictWriter(fh, fieldnames=names, delimiter=delimiter)
        writer.writerow(CSV_HEADERS)
        writer.writerows(asdict(lead) for lead in leads)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Busca comércios locais na Google Places API (New) e salva em CSV."
    )
    parser.add_argument(
        "termo",
        nargs="*",
        help="Termo de busca, ex.: \"padaria em Eldorado, Contagem\"",
    )
    parser.add_argument(
        "-o",
        "--saida",
        default=DEFAULT_OUTPUT,
        help=f"Arquivo CSV de saída (padrão: {DEFAULT_OUTPUT})",
    )
    parser.add_argument(
        "-m",
        "--max",
        type=int,
        default=MAX_RESULTS,
        choices=range(1, MAX_RESULTS + 1),
        metavar=f"1-{MAX_RESULTS}",
        help=f"Máximo de resultados (padrão: {MAX_RESULTS})",
    )
    parser.add_argument(
        "--separador",
        default=";",
        help="Separador do CSV. ';' abre direto no Excel em português (padrão: ';')",
    )
    parser.add_argument(
        "--chave",
        help=f"Chave da API. Prefira a variável de ambiente {API_KEY_ENV}.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    args = parse_args(argv)

    api_key = args.chave or os.environ.get(API_KEY_ENV)
    if not api_key:
        log.error("Defina a chave da API em %s ou use --chave.", API_KEY_ENV)
        return 2

    query = " ".join(args.termo).strip()
    if not query:
        try:
            query = input("Termo de busca: ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return 130
    if not query:
        log.error("O termo de busca não pode ficar vazio.")
        return 2

    log.info("Buscando: %s", query)
    try:
        with build_session(api_key) as session:
            places = search_places(session, query, max_results=args.max)
    except PlacesAPIError as exc:
        log.error("%s", exc)
        return 1

    if not places:
        log.warning("Nenhum resultado encontrado. O CSV não foi criado.")
        return 0

    leads = [Lead.from_place(p) for p in places]
    output = Path(args.saida)
    try:
        save_csv(leads, output, delimiter=args.separador)
    except OSError as exc:
        log.error("Não foi possível salvar %s: %s", output, exc)
        return 1

    log.info("%d lead(s) salvos em %s", len(leads), output.resolve())
    return 0


if __name__ == "__main__":
    sys.exit(main())
