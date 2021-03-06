"""Remove all data for satellites, which are declared as unhealthy in GNSS broadcast ephemeris

Description:
------------

Removes all observations of unhealthy satellites, if `remover` is selected by `True`.

"""
# External library imports
import numpy as np

# Where imports
from where import apriori
from where.lib import log
from where.lib import plugins


@plugins.register
def ignore_unhealthy_satellite(dset):
    """Remove all data for satellites, which are declared as unhealthy in GNSS broadcast ephemeris

    If a satellite is set to unhealthy (brdc.sv_health > 0) in one of the given broadcast ephemeris blocks, then the
    satellite observations are removed.

    The definition of the satellite vehicle health flags depends on GNSS:
        - GPS: see section 20.3.3.3.1.4 in :cite:`is-gps-200h`
        - Galileo: see section 5.1.9.3 in :cite:`os-sis-icd`
        - BeiDou: see section 5.2.4.6 in :cite:`bds-sis-icd`
        - QZSS: see section 4.1.2.3 in :cite:`is-qzss-pnt-001`
        - IRNSS: see section 6.2.1.6 in :cite:`irnss-icd-sps`

    Args:
        dset (Dataset):   A Dataset containing model data.

    Returns:
        numpy.ndarray:    Array containing False for observations to throw away
    """
    remove_idx = np.zeros(dset.num_obs, dtype=bool)

    # Get unhealthy satellites information from GNSS broadcast orbits
    brdc = apriori.get(
        "orbit",
        rundate=dset.rundate,
        time=dset.time,
        satellite=tuple(dset.satellite),
        system=tuple(dset.system),
        station=dset.vars["station"],
        apriori_orbit="broadcast",
    )
    unhealthy_satellites = brdc.unhealthy_satellites()

    if not set(unhealthy_satellites).intersection(dset.satellite):
        log.info("The unhealthy satellites {} are not given in Dataset.", ", ".join(unhealthy_satellites))
        return np.logical_not(remove_idx)

    # Remove unhealthy satellites
    if unhealthy_satellites:
        log.info("Discarding observations for unhealthy satellites: {}", ", ".join(unhealthy_satellites))
        for satellite in unhealthy_satellites:
            remove_idx = np.logical_or(remove_idx, dset.filter(satellite=satellite))

    return np.logical_not(remove_idx)
