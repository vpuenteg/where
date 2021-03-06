"""Framework for calculating satellite orbit models

Description:
------------

Each orbit model should be defined in a separate .py-file. The function inside the .py-file that should be called need
to be decorated with the :func:`~where.lib.plugins.register` decorator as follows::

    from where.lib import plugins

    @plugins.register
    def gravity_earth(...):
        ...

The decorated function will be called with several parameters::

    TODO: Document parameters


References:
-----------

[1] Montenbruck, Oliver and Gill, Eberhard: Satellite Orbits, Springer Verlag, 2000.




"""
