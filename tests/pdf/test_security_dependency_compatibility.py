"""Retained invoice output must work with patched dependency security floors."""

import builtins
import importlib.metadata
import importlib.util
import math
import os
import re
from copy import deepcopy
from decimal import Decimal
from pathlib import Path

import pytest
from pypdf import PdfReader

from vastai.pdf import vast_pdf


@pytest.mark.parametrize(
    "count,charge_amount",
    [(n, "1.25") for n in [0, 1, 18, 19, 48, 49]] + [(1, "0.58"), (19, "0.58")],
)
def test_invoice_security_dependency_compatibility(
    tmp_path, monkeypatch, count, charge_amount
):
    monkeypatch.chdir(tmp_path)
    if os.environ.get("SPARKLES_QUALIFICATION_ARTIFACTS"):
        # The qualification helper certifies an installed wheel. Normal local
        # development also supports the manifest's editable source dependency.
        installed = Path(importlib.metadata.distribution("vastai").locate_file(""))
        assert Path(vast_pdf.__file__).resolve().is_relative_to(installed.resolve())
    assert importlib.metadata.version("pillow").startswith("13.")
    assert importlib.metadata.version("cryptography").startswith("50.")
    user = {
        "fullname": "QA Customer",
        "billaddress_line1": "1 Test Street",
        "billaddress_line2": "Unit 2",
        "billaddress_city": "Test City",
        "billaddress_zip": "00000",
    }
    rows = [
        {
            "type": "charge" if index % 2 == 0 else "payment",
            "timestamp": 1700000000 + index,
            "amount": charge_amount if index % 2 == 0 else "-0.25",
            "is_credit": index % 2 == 1,
            "last4": "0000",
            "description": f"Synthetic item {index}",
            "quantity": "1",
            "rate": "1.25",
        }
        for index in range(count)
    ]
    expected = sum((Decimal(row["amount"]) for row in rows), Decimal(0))
    output = tmp_path / "synthetic-invoice.pdf"
    vast_pdf.generate_invoice(
        user,
        deepcopy(rows),
        {"header_text": "Synthetic qualification only", "pdf_filename": str(output)},
    )
    pages = max(1, 1 + math.ceil(max(0, count - 18) / 30))
    for path in (output, tmp_path / "latest-invoice.pdf"):
        reader = PdfReader(path)
        assert len(reader.pages) == pages
        text = "\n".join(page.extract_text() for page in reader.pages)
        assert "QA Customer" in text and "Synthetic qualification only" in text
        assert all(len(page.images) >= 1 for page in reader.pages)
        if count:
            sign = "-" if expected > 0 else ""
            total = re.escape(f"{abs(expected):.2f}")
            assert re.search(r"Total\s*" + re.escape(sign) + r"\$\s*" + total, text), (
                text
            )
            assert f"Synthetic item {count - 1}" in text
        else:
            assert "NO DATA" in text
            assert "$-0.00" not in text


def test_pdf_dependency_import_error_keeps_original_cause(monkeypatch):
    original = builtins.__import__

    def blocked(name, *args, **kwargs):
        if name.startswith("borb"):
            raise ImportError("synthetic missing PDF dependency")
        return original(name, *args, **kwargs)

    spec = importlib.util.spec_from_file_location(
        "vast_pdf_dependency_probe", vast_pdf.__file__
    )
    module = importlib.util.module_from_spec(spec)
    with monkeypatch.context() as patch:
        patch.setattr(builtins, "__import__", blocked)
        with pytest.raises(ImportError, match="compatible borb") as caught:
            spec.loader.exec_module(module)
    assert str(caught.value.__cause__) == "synthetic missing PDF dependency"


@pytest.mark.parametrize(
    "amounts,negative,expected",
    [
        (["0.58"], False, 0.58),
        (["0.585", "0.295"], False, 0.87),
        (["-0.581"], False, -0.59),
        (["0.58"], True, -0.58),
    ],
)
def test_invoice_cent_totals_preserve_floor_semantics(amounts, negative, expected):
    assert (
        vast_pdf.compute_column_sum(
            [{"amount": value} for value in amounts], "amount", negative
        )
        == expected
    )


@pytest.mark.parametrize(
    "value,expected", [(1.25, "-$1.25"), (-0.25, "$0.25"), (0.0, "$0.00")]
)
def test_invoice_currency_keeps_sign_attached_to_amount(value, expected):
    assert vast_pdf.format_float_val_as_currency(value) == expected
