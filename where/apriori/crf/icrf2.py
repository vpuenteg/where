"""A module to provide information from radio sources defined in ICRF2

Description:
------------

Reads source positions ICRF2 files. Source positions are considered constant in ICRF2. See :cite:'icrf2009'

References:
-----------




"""

# External library imports
import numpy as np

# Where imports
from where.apriori import crf
from where.lib import files
from where.lib import log
from where.lib import plugins
from where import parsers
from where.lib import rotation
from where.ext import sofa_wrapper as sofa
from where.lib.time import Time
from where.lib.unit import unit


@plugins.register
class Icrf2(crf.CrfFactory):
    """A class to provide information from radio sources defined in ICRF2
    """

    def _read_data(self):
        """Read data needed by this Reference Frame for calculating positions of sites

        Delegates to _read_data_<self.format> to read the actual data.

        Returns:
            Dict:  Dictionary containing data about each site defined in this reference frame.
        """
        data = parsers.parse_key(file_key="icrf2_non_vcs").as_dict()
        data.update(parsers.parse_key(file_key="icrf2_vcs_only").as_dict())

        return data

    def _calculate_pos_crs(self, source):
        """Calculate position for a source

        Args:
            source (String):    Key saying which source to calculate position for.

        Returns:
            Array:  Positions, one 2-vector
        """
        source_info = self.data[source]
        return np.array([source_info["ra"], source_info["dec"]])
