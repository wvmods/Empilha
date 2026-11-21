#!/usr/bin/env python3
"""Configura o app de Windows do Empilha depois do `flutter create --platforms=windows`.

Define: nome do .exe (empilha.exe), título e tamanho da janela (900x1000),
metadados do executável (aba Detalhes) e o ícone próprio (app_icon.ico).

Uso (na raiz do projeto): python tools/setup_windows.py
"""
import os
import re
import subprocess
import sys

APP = "Empilha"
EXE = "empilha"
ORG = "Empilha Game"


def edit(path, fn):
    if not os.path.exists(path):
        print("AVISO: não achei", path)
        return
    with open(path, encoding="utf-8", errors="ignore") as f:
        old = f.read()
    new = fn(old)
    with open(path, "w", encoding="utf-8") as f:
        f.write(new)
    print("ok:", path)


def cmake(t):
    return re.sub(r'set\(BINARY_NAME\s+"[^"]*"\)', f'set(BINARY_NAME "{EXE}")', t)


def main_cpp(t):
    t = re.sub(r'window\.Create\(L"[^"]*"', f'window.Create(L"{APP}"', t)
    return re.sub(r"Win32Window::Size size\(\d+,\s*\d+\)", "Win32Window::Size size(900, 1000)", t)


def rc(t):
    def val(key, v):
        return rf'(VALUE "{key}",\s*)"[^"]*"'

    for key, v in [
        ("CompanyName", ORG),
        ("FileDescription", APP),
        ("InternalName", EXE),
        ("OriginalFilename", EXE + ".exe"),
        ("ProductName", APP),
    ]:
        t = re.sub(val(key, v), lambda m, v=v: m.group(1) + f'"{v}"', t)
    t = re.sub(r'(VALUE "LegalCopyright",\s*)"[^"]*"', lambda m: m.group(1) + f'"Copyright (C) 2026 {ORG}"', t)
    return t


def main():
    edit("windows/CMakeLists.txt", cmake)
    edit("windows/runner/main.cpp", main_cpp)
    edit("windows/runner/Runner.rc", rc)
    here = os.path.dirname(os.path.abspath(__file__))
    ico = os.path.join("windows", "runner", "resources", "app_icon.ico")
    subprocess.check_call([sys.executable, os.path.join(here, "make_icon.py"), "--ico", ico])


if __name__ == "__main__":
    main()
