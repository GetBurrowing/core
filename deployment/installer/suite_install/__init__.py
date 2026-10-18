"""Old name of ``burrow_install``, kept so ``python3 -m suite_install`` still runs.

The installer package was renamed to ``burrow_install`` (task 01a14dd8). This
package holds only ``__main__``: it prints one deprecation line on stderr and
runs ``burrow_install.__main__.main`` with the same argv and exit code. Nothing
else lives here, so ``import suite_install.<module>`` fails on purpose.
"""
