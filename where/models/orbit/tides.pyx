# cython: profile=True
"""Calculates the force on the satellite from the solid earth tides and ocean tides

Description:

This model calculates the gravitational force based on the corrections to the gravity field coefficients C and S
following IERS Conventions 2010 [2], Chapter 5 and 6.

References:
[1] Montenbruck, Oliver and Gill, Eberhard, Satellite Orbits, Springer Verlag, 2000.

[2] Petit, G. and Luzum, B. (eds.), IERS Conventions (2010), IERS Technical Note No. 36, BKG (2010)



$Revision: 15003 $
$Date: 2018-05-04 15:38:08 +0200 (Fri, 04 May 2018) $
$LastChangedBy: fauing $
"""
# Standard library imports
import math

# External library imports
import numpy as np

# Where imports
from where import apriori
from where.lib import config
from where.lib import constant
from where.lib import log
from where.ext import sofa

cdef double GM_earth, R_earth, GM_moon, GM_sun
cdef int truncation_level
cdef double[:, :] sun_pos, moon_pos
cdef double[:] sun_distance, moon_distance
cdef Cp, Cm, Sp, Sm
cdef epoch_list
cdef double[:] GMST
cdef double[:, :, :] g2i

def register_entry_point():
    """Register entry points for setup and later calls."""
    return dict(call=tides, setup=tides_setup)

def tides_setup(rundate, force_parameters, sat_name, double[:] time_grid, epochs, body_pos_gcrs, body_pos_itrs, bodies, gcrs2itrs):
    """Set up module variables used later during calculation.
    
    Args: 
        rundate:           Time of integration start
        force_parameters:  Dict of parameters to be estimated
        sat_name:          Name of satellite
        time_grid:         Table of times in seconds since rundate, in utc. 
        epochs:            time_grid converted to Time objects, in utc.
        body_pos_gcrs:     The positions of the bodies in the solar system in GCRS.
        body_pos_itrs:     The positions of the bodies in the solar system in ITRS.
        bodies:            List of bodies
        gcrs2itrs:         List of transformation matrices, one for each time in epochs.
    """

    global GM_earth, G_earth, GM_moon, GM_sun, R_earth
    global truncation_level
    global moon_pos, sun_pos, moon_distance, sun_distance
    global Cp, Cm, Sp, Sm
    global epoch_list, GMST
    global g2i
    epoch_list = epochs
 
    GM_earth = constant.get('GM', source='egm_2008')
    R_earth = constant.get('a', source='egm_2008')
    GM_moon = constant.get('GM_moon')
    GM_sun = constant.get('GM_sun')

    # Ocean tides coefficients, corrections to the gravity coefficients C and S.
    # The dict containing the values Cp, Cm, Sp and Sm
    ocean_tides_coeffs = apriori.get('ocean_tides_orbit')
    
    Cp = ocean_tides_coeffs['C+']
    Cm = ocean_tides_coeffs['C-']
    Sp = ocean_tides_coeffs['S+']
    Sm = ocean_tides_coeffs['S-']

    # Read configuration settings
    truncation_level = config.tech.gravity_truncation_level.int

    # Tides from Moon:
    idx_moon = bodies.index('moon')
    moon_pos = body_pos_itrs[idx_moon, :, :]
    moon_distance = np.linalg.norm(moon_pos, axis=1)
    
    # Tides from the Sun:
    idx_sun = bodies.index('sun')
    sun_pos = body_pos_itrs[idx_sun, :, :]
    sun_distance = np.linalg.norm(sun_pos, axis=1)

    GMST = epochs.sidereal_time('mean', longitude='greenwich').to('radian').value
    g2i = gcrs2itrs
    
def tides(double[:] sat_pos_itrs, int num_param, int current_step, **_not_used):
    """Compute force on satellite from the gravity field of the earth

    Following section 3.2.5 in Montenbruck and Gill [1] we calculate the acceleration caused by the gravity field of
    the earth from the gravity field coefficients \f$ C_{nm} \f$ and \f$ S_{nm} \f$, in addition to the Legendre terms
    \f$ V_{nm} \f$ and \f$ W_{nm} \f$ using equation (3.33).

    In addition, we calculate the transition matrix \f$ \phi \f$ using equation (7.42),

    \f[ \dot{\vec \phi}(t, t_0) = \left( \begin{array}{cc} 0_{3 \times 3} &
    I_{3 \times 3} \\ \frac{\partial \ddot{\vec r}(\vec r, \dot{\vec r}, t)}{
    \partial \vec r(t)} & \frac{\partial \ddot{\vec r}(\vec r, \dot{\vec r},
    t)}{\partial \dot{\vec r}(t)} \end{array} \right) \cdot \vec \phi(t, t_0)
    . \f]

    The acceleration with respect to position (lower left corner) is calculated using the equations (7.65) to (7.69).

    The terms \f$ V, W \f$ are required up to degree and order 2 higher than the truncation level of the gravity field,
    as can be seen from the equations for the transition matrix.

    The calculation of the gravity field of the earth is done in the earth fixed ITRS system. the coordinates are
    transformed to the space-fixed GCRS system before they are returned, according to equations (3.34) and (7.70).

    Args:
        sat_pos_itrs:      Satellite position in ITRS.
        num_param:         Number of force parameters to be estimated.
        current_step:      The current step number of the integrator.
        _not_used:         Unused variables.

    Returns:
        Acceleration and transition matrix due to tides in the GCRS system.

    """
    cdef int i, n, m, f
    cdef double[:, :] V, W
    V, W = compute_VW(sat_pos_itrs)
    
    cdef double[:] acc = np.zeros(3)
    cdef double[:] delaunay_variables
    gcrs2itrs = g2i[current_step]
   
    # Need Greenwich mean sidereal time
    time_now = epoch_list[current_step]
    delaunay_variables = delaunay(time_now.tt.jd)

    cdef double [:, :] C, S
    cdef double[:, :] trans, trans_gcrs, sens_itrs, sens_gcrs
    cdef double dxx, dxy, dxz, dyz, dzz
    dxx = 0
    dxy = 0
    dxz = 0
    dyz = 0
    dzz = 0

    C, S = solid_earth_tides(gcrs2itrs, delaunay_variables, current_step)
    # The ocean tides model does not seem to improve RMS on Lageos, but increases computation time.
    # C, S = ocean_tides(C, S, GMST[current_step], delaunay_variables)

    for n in range(0, truncation_level):
        for m in range(0, n + 1):
            f = (n - m + 2) * (n - m + 1)    # Scaling factor
            
            # The m = 0 case is handled separately:
            if m == 0:
                acc[0] += -C[n, 0] * V[n+1, 1]
                acc[1] += -C[n, 0] * W[n+1, 1]
                acc[2] += (n + 1) * (-C[n, 0] * V[n+1, 0] - S[n, 0] * W[n+1, 0])
                dxx += (C[n, 0] * V[n+2, 2] - f * C[n, 0] * V[n+2, 0]) / 2
                dxy += C[n, 0] * W[n+2, 2] / 2
                dxz += (n + 1) * C[n, 0] * V[n+2, 1]
                dyz += (n + 1) * C[n, 0] * W[n+2, 1]
                dzz += f * (C[n, 0] * V[n+2, 0] + S[n, 0] * W[n+2, 0])
                continue

            # For some derivatives also m=1 needs special treatment
            if m == 1:
                dxx += (C[n, 1] * V[n + 2, 3] + S[n, 1] * W[n + 2, 3]
                        + f * (-3 * C[n, 1] * V[n + 2, 1] - S[n, 1] * W[n+2, 1])) / 4
                dxy += (C[n, 1] * W[n + 2, 3] - S[n, 1] * V[n + 2, 3]
                        + f * (-C[n, 1] * W[n + 2, 1] - S[n, 1] * V[n + 2, 1])) / 4
            else:
                dxx += (C[n, m] * V[n + 2, m + 2] + S[n, m] * W[n + 2, m + 2] + 2 * (n - m + 2) * (n - m + 1)
                        * (-C[n, m] * V[n + 2, m] - S[n, m] * W[n + 2, m]) + (n - m + 4) * (n - m + 3) * (n - m + 2)
                        * (n - m + 1) * (C[n, m] * V[n + 2, m - 2] + S[n, m] * W[n + 2, m - 2])) / 4
                dxy += (C[n, m] * W[n + 2, m + 2] - S[n, m] * V[n + 2, m + 2] + (n - m + 4) * (n - m + 3) * (n - m + 2)
                        * (n - m + 1) * (-C[n, m] * W[n + 2, m - 2] + S[n, m] * V[n + 2, m - 2])) / 4

            # For 0 < m <= n:
            f = (n - m + 2) * (n - m + 1)    # Scaling factor
            acc[0] += ((-C[n, m] * V[n + 1, m + 1] - S[n, m] * W[n + 1, m + 1])
                       + f * (C[n, m] * V[n + 1, m - 1] + S[n, m] * W[n + 1, m - 1])) / 2
            acc[1] += ((-C[n, m] * W[n + 1, m + 1] + S[n, m] * V[n + 1, m + 1])
                       + f * (-C[n, m] * W[n + 1, m - 1] + S[n, m] * V[n + 1, m - 1])) / 2
            acc[2] += (n - m + 1) * (-C[n, m] * V[n + 1, m] - S[n, m] * W[n + 1, m])

            dxz += ((n - m + 1) * (C[n, m] * V[n + 2, m + 1] + S[n, m] * W[n + 2, m + 1]) + (n - m + 3) * f *
                    (-C[n, m] * V[n + 2, m - 1] - S[n, m] * W[n + 2, m - 1])) / 2
            dyz += ((n - m + 1) * (C[n, m] * W[n + 2, m + 1] - S[n, m] * V[n + 2, m + 1]) + (n - m + 3) * f *
                    (C[n, m] * W[n + 2, m - 1] - S[n, m] * V[n + 2, m - 1])) / 2
            dzz += f * (C[n, m] * V[n + 2, m] + S[n, m] * W[n + 2, m])


    for i in range(3):
        acc[i] *= GM_earth / R_earth**2
    
    cdef double fact = GM_earth / R_earth**3

    dxx *= fact
    dxy *= fact
    dxz *= fact
    dzz *= fact
    dyz *= fact

    trans = np.array([[dxx, dxy, dxz], [dxy, -dxx - dzz, dyz], [dxz, dyz, dzz]])
    trans_gcrs = np.zeros((3, 6))
    gcrs2itrs = g2i[current_step]

    for i in range(0, 3):
        for j in range(0, 3):
            for k in range(0, 3):
                for l in range(0, 3):
                    trans_gcrs[i, j] += gcrs2itrs[k, i] * trans[k, l] * gcrs2itrs[l, j]

    sens_itrs = np.zeros((3, num_param))
    sens_gcrs = np.zeros((3, num_param))
    
    for i in range(0, 3):
        for j in range(0, num_param):
            for k in range(0, 3):
                sens_gcrs[i, j] += gcrs2itrs[k, i] * sens_itrs[k, l]

    # Transform to space fixed system before returning, eqs (3.34) and (7.70)
    return (np.dot(gcrs2itrs.T, acc), trans_gcrs, sens_gcrs)



cdef compute_VW(double[:] pos_xyz):
    """Computing the V- and W-coefficients V and W recursively

    The V- and W-coefficients are based on Legendre polynomials, and used when calculating the gravity potential. The
    coefficients are calculated using recurrence relations as described in section 3.2.4 of Montenbruck and Gill [1].

    Args:
        pos_xyz:          Position of satellite as a 3-vector.
    Returns:
        Two matrices V and W with coefficients.
    """
    cdef double[:, :] V = np.zeros((truncation_level + 2, truncation_level + 2))
    cdef double[:, :] W = np.zeros((truncation_level + 2, truncation_level + 2))
    a = R_earth
    cdef double x, y, z, r, f
    cdef int n, m
    
    x, y, z = pos_xyz
    r = np.linalg.norm(pos_xyz)

    f = a / r**2   # Common factor

    V[0, 0] = a / r
    V[1, 0] = z * f * V[0, 0]

    # First compute the zonal terms V[n,0]. The terms W[n,0] are always zero.
    for n in range(2, truncation_level + 2):
        V[n, 0] = f * ((2 * n - 1) * z * V[n - 1, 0] - (n - 1) * a * V[n - 2, 0]) / n

    for m in range(1, truncation_level + 2):
        # Compute the diagonal matrix elements, called the tesseral terms.
        V[m, m] = (2 * m - 1) * f * (x * V[m - 1, m - 1] - y * W[m - 1, m - 1])
        W[m, m] = (2 * m - 1) * f * (x * W[m - 1, m - 1] + y * V[m - 1, m - 1])

        # Compute the remaining terms
        for n in range(m + 1, truncation_level + 2):
            V[n, m] = f * ((2 * n - 1) * z * V[n - 1, m] - (n + m - 1) * a * V[n - 2, m]) / (n - m)
            W[n, m] = f * ((2 * n - 1) * z * W[n - 1, m] - (n + m - 1) * a * W[n - 2, m]) / (n - m)

    return V, W


cdef solid_earth_tides(double[:, :] gcrs2itrs, double[:] delaunay_variables, int current_step):
    """Computing the time variable part of the gravity coefficients of the Earth, following chapter 6 in
    IERS Conventions [2].

    Args:
        gcrs2itrs:           Matrix for transforming from gcrs to itrs.
        delaunay_variables:  Variables for use in tidal model, described in Section 5.7 in IERS Conventions [2].
        current_step:        Current step number of the integrator
        
    Returns:
        C,S:                 Tides part of Gravity coefficients at time t.
    """
    # Elastic or anelastic earth?
    k = k_elastic
    #k = k_anelastic

    cdef int n, m
    cdef double[:, :] C, S
    cdef double longitude_moon, latitude_moon, longitude_sun, latitude_sun
    cdef complex factor_sun, factor_moon, correction
    V_sun, W_sun = compute_VW(sun_pos[current_step])
    V_moon, W_moon = compute_VW(moon_pos[current_step])
 
    C = np.zeros((truncation_level, truncation_level))
    S = np.zeros((truncation_level, truncation_level))
    # Earth-fixed geodetic coordinates of the Moon.
    longitude_moon, latitude_moon, _, _ = sofa.iau_gc2gd(1, moon_pos[current_step])

    # Earth-fixed geodetic coordinates of the Sun.
    longitude_sun, latitude_sun, _, _ = sofa.iau_gc2gd(1, sun_pos[current_step])

    sun_distance_now = sun_distance[current_step]
    moon_distance_now = moon_distance[current_step]
    # Compute the non-normalized coefficients here.
    # Equation (6.6)
    for n in range(2, min(4, C.shape[0])):
        for m in range(0, n + 1):
            factor_moon = k(n, m) / (2 * n + 1) * (GM_moon / GM_earth) 
            factor_sun = k(n, m) / (2 * n + 1) * (GM_sun / GM_earth) 

            correction = (factor_moon * V_moon[n, m] + factor_sun * V_sun[n, m] + 
                          (factor_moon * W_moon[n, m] + factor_sun * W_sun[n, m]) * 1j)

            C[n, m] = correction.real * normalization_factor(n, m)**2
            S[n, m] = correction.imag * normalization_factor(n, m)**2

    # Treat the n=4 case separately:
    # Equation (6.7)
    if C.shape[0] > 4:
        for m in range(0, 3):
            factor_moon = k(4, m) / 5 * (GM_moon / GM_earth) 
            factor_sun = k(4, m) / 5 * (GM_sun / GM_earth) 
            correction = (factor_moon * V_moon[2, m] + factor_sun * V_sun[2, m]
                          + 1j * (factor_moon * W_moon[2, m] + factor_sun * W_sun[2, m]))
            C[4, m] = correction.real * normalization_factor(2, m) * normalization_factor(4, m)
            S[4, m] = correction.imag * normalization_factor(2, m) * normalization_factor(4, m)

    # Eqation (6.8a)
    C[2, 0] += normalization_factor(2, 0) * equation_68a(delaunay_variables)
    
    # Equation (6.8b) with m=1.
    correction1, correction2 = equation_68b_m1(GMST[current_step], delaunay_variables)
    C[2, 1] += normalization_factor(2, 1) * correction1
    S[2, 1] += normalization_factor(2, 1) * correction2

    # Equation (6.8b) with m=2.
    correction3, correction4 = equation_68b_m2(GMST[current_step], delaunay_variables)
    C[2, 2] += normalization_factor(2, 2) * correction3
    S[2, 2] += normalization_factor(2, 2) * correction4

    return C, S


def ocean_tides(C, S, GMST, delaunay_variables):
    """Computing the time variable part of the gravity coefficients of the Earth due to ocean tides

    Following chapter 6.3 in [2].

    Args:
        C,S:                 Gravity coefficients without ocean tides.
        GMST:                Greenwich mean sidereal times.
        delaunay_variables:  Variables for use in tidal model, described in Section 5.7 in IERS Conventions [2].

    Returns:
        C, S:                Time variable part of gravity coefficients with ocean tides at time t.
    """
    delaunay_multipliers_a, _, _, doodson_a = table_65a()
    delaunay_multipliers_b, _, _, doodson_b = table_65b()
    delaunay_multipliers_c, _, doodson_c = table_65c()

    # Equation 6.15
    for n in range(0, C.shape[0]):
        for m in range(0, n + 1):
            for doodson in Cp[n, m]:
                delaunay_multipliers = []
                # Look up the right frequency component from the right table:
                for i in range(0, len(doodson_a)):
                    if doodson == doodson_a[i]:
                        delaunay_multipliers = delaunay_multipliers_a[i]
                        break
                for i in range(0, len(doodson_b)):
                    if doodson == doodson_b[i]:
                        delaunay_multipliers = delaunay_multipliers_b[i]
                        break
                for i in range(0, len(doodson_c)):
                    if doodson == doodson_c[i]:
                        delaunay_multipliers = delaunay_multipliers_c[i]
                        break
                if delaunay_multipliers == []:
                    break

                sin_theta_f = math.sin(m * (GMST + math.pi) - np.dot(delaunay_multipliers, delaunay_variables))
                cos_theta_f = math.cos(m * (GMST + math.pi) - np.dot(delaunay_multipliers, delaunay_variables))

                C[n, m] += normalization_factor(n, m)**2 * (Cp[n, m][doodson] * cos_theta_f 
                                + Sp[n, m][doodson] * sin_theta_f + Cm[n, m][doodson] * cos_theta_f 
                                + Sm[n, m][doodson] * sin_theta_f)
                S[n, m] += normalization_factor(n, m)**2 * (-Cp[n, m][doodson] * sin_theta_f 
                                + Sp[n, m][doodson] * cos_theta_f + Cm[n, m][doodson] * sin_theta_f 
                                - Sm[n, m][doodson] * cos_theta_f)
    return C, S


cdef k_elastic(int n, int m):
    """
    The k coefficients are taken from IERS Conventions [2], table 6.3 on page 83, where Elastic Earth is assumed.

    Args:
        n, m:   Integers, degree and order.
    Returns:
        k:      Float, solid Earth tide external potential Love numbers.
    """
    cdef double k
    if n == 2 and m == 0:
        k = 0.29525
    elif n == 4 and m == 0:
        k = -0.00087
    elif n == 2 and m == 1:
        k = 0.29470
    elif n == 4 and m == 1:
        k = -0.00079
    elif n == 2 and m == 2:
        k = 0.29801
    elif n == 4 and m == 2:
        k = -0.00057
    elif n == 3:
        if 0 <= m <= 2:
            k = 0.093
        elif m == 3:
            k = 0.094
        else:
            k = 0
    else:
        k = 0

    return k


cdef k_anelastic(int n, int m):
    """
    The k coefficients are taken from IERS Conventions [2], table 6.3 on page 83, where Anelastic Earth is assumed.

    Args:
        n, m:    Integers, degree and order
    Returns:
        k:       Complex number, solid Earth tide external potential Love numbers.
    """
    cdef complex k

    if n == 2:
        if m == 0:
            k = 0.30190
        elif m == 1:
            k = equation_69(n)
            k += 0.29830 - 0.00144 * 1j
        elif m == 2:
            k = 0.30102 - 0.0013 * 1j
        else:
            k = 0
    elif n == 4:
        if m == 0:
            k = -0.00089
        elif m == 1:
            k = equation_69(n)
            k += -0.0008
        elif m == 2:
            k = -0.00057
        else:
            k = 0
    else:
        k = 0

    return k


cdef equation_68a(double[:] delaunay_variables):
    """
    Equation (6.8a) in IERS Conventions [2].

    Args:
        delaunay_variables:  Variables for use in tidal model, described in Section 5.7 in IERS Conventions [2].
    Returns:
        float:               Contribution to the gravity coefficient C20 from equation 6.8a.
    """
    cdef long [:, :] delaunay_multipliers
    cdef double[:] ip, op
    cdef double[:] sin_theta_f
    cdef double[:] cos_theta_f

    delaunay_multipliers, ip, op, _ = table_65b()
    sin_theta_f = np.zeros(delaunay_multipliers.shape[0])
    cos_theta_f = np.zeros(delaunay_multipliers.shape[0])

    for i in range(0, delaunay_multipliers.shape[0]):
        argument = np.dot(delaunay_multipliers[i], delaunay_variables)
        sin_theta_f[i] = math.sin(argument)
        cos_theta_f[i] = math.cos(argument)


    return (np.dot(cos_theta_f, ip) - np.dot(sin_theta_f, op)) * math.sqrt(5)


cdef table_65b():
    """Table (6.5b) in IERS Conventions [2]

    Returns:
        delaunay_multipliers:   Matrix, numbers to be multiplied by the
                                Delaunay variables
        ip:                     vector of in-phase amplitudes
        op:                     vector of out-of-phase amplitudes

    Notes: theta_f is computed as the sum over n_i * beta_i, see page 84 in the reference above.
           theta_f is a vector, with different values for every frequency f.
    """

    # Delaunay multipliers
    # cdef long[:, :] delaunay_multipliers
    # cdef double[:] ip, op, doodson
    cdef int i
    delaunay_multipliers = np.array([[0, 0, 0, 0, 1], [0, 0, 0, 0, 2], [0, -1, 0, 0, 0], [0, 0, -2, 2, -2],
                                      [0, 0, -2, 2, -1], [0, -1, -2, 2, -2], [1, 0, 0, -2, 0], [-1, 0, 0, 0, -1],
                                      [-1, 0, 0, 0, 0], [-1, 0, 0, 0, 1], [1, 0, -2, 0, -2], [0, 0, 0, -2, 0],
                                      [-2, 0, 0, 0, 0], [0, 0, -2, 0, -2], [0, 0, -2, 0, -1], [0, 0, -2, 0, 0],
                                      [1, 0, -2, -2, -2], [-1, 0, -2, 0, -2], [-1, 0, -2, 0, -1], [0, 0, -2, -2, -2],
                                      [-2, 0, -2, 0, -2]])

    # In-phase amplitude
    ip = np.array([
        16.6, -0.1, -1.2, -5.5, 0.1, -0.3, -0.3, 0.1, -1.2, 0.1, 0.1, 0.0, 0.0, 0.6, 0.2, 0, 0.1, 0.4, 0.2, 0.1, 0.1
        ])

    # Out-of-phase amplitude
    op = np.array([
        -6.7, 0.1, 0.8, 4.3, -0.1, 0.2, 0.7, -0.2, 3.7, -0.2, -0.2, 0.6, 0.3, 6.3, 2.6, 0.2, 0.2, 1.1, 0.5, 0.2, 0.1
        ])

    # Units: 10**-12
    for i in range(0, len(ip)):
        ip[i] = ip[i] * 10e-12
        op[i] = op[i] * 10e-12

    doodson = np.array([55.565, 55.575, 56.554, 57.555, 57.565, 58.554, 63.655, 65.445, 65.455, 65.465, 65.655, 73.555,
                        75.355, 75.555, 75.565, 75.575, 83.655, 85.455, 85.465, 93.555, 95.355])

    return delaunay_multipliers, ip, op, doodson


cdef equation_68b_m1(double GMST, double[:] delaunay_variables):
    """
    Equation (6.8b) (with m=1) in the reference below.

    Reference: Petit, G. and Luzum, B. (eds.), IERS Conventions (2010),
                              IERS Technical Note No. 36, BKG (2010).
    """
    cdef long[:, :] delaunay_multipliers
    cdef double[:] ip, op, sin_theta_f, cos_theta_f
    delaunay_multipliers, ip, op, _ = table_65a()

    sin_theta_f = np.zeros(delaunay_multipliers.shape[0])
    cos_theta_f = np.zeros(delaunay_multipliers.shape[0])

    for i in range(0, delaunay_multipliers.shape[0]):
        sin_theta_f[i] = math.sin(GMST + math.pi - np.dot(delaunay_multipliers[i], delaunay_variables))
        cos_theta_f[i] = math.cos(GMST + math.pi - np.dot(delaunay_multipliers[i], delaunay_variables))

    return math.sqrt(5 / 3) * (np.dot(cos_theta_f, op) + np.dot(sin_theta_f, ip)), -math.sqrt(5 / 3) * (-np.dot(cos_theta_f, ip) + np.dot(sin_theta_f, op))



cdef table_65a():
    """Computation of a list of cos_theta_f and sin_theta_f for
    different frequencies f from Table (6.5a) in the reference below.

    Reference: Petit, G. and Luzum, B. (eds.), IERS Conventions (2010),
                                 IERS Technical Note No. 36, BKG (2010).

    Returns:
         sin_theta_f: vector with entries sinus(theta_f) for various f, see notes.
         cos_theta_f: vector with entries cos(theta_f) for various f, see notes
         ip:          vector of in-phase amplitudes
         op:          vector of out-of-phase amplitudes

    Notes: theta_f is computed as the sum over n_i * beta_i, see page 84 in the reference above.
           theta_f is a vector, with entries the values of this sum for every frequency f.
    """

    # Delaunay multipliers
    delaunay_multipliers = np.array([
        [2, 0, 2, 0, 2], [0, 0, 2, 2, 2], [1, 0, 2, 0, 1], [1, 0, 2, 0, 2], [-1, 0, 2, 2, 2], [0, 0, 2, 0, 1],
        [0, 0, 2, 0, 2], [0, 0, 0, 2, 0], [1, 0, 2, -2, 2], [-1, 0, 2, 0, 1], [-1, 0, 2, 0, 2], [1, 0, 0, 0, 0],
        [1, 0, 0, 0, 1], [-1, 0, 0, 2, 0], [-1, 0, 0, 2, 1], [0, 1, 2, -2, 2], [0, 0, 2, -2, 1], [0, 0, 2, -2, 2],
        [0, -1, 2, -2, 2], [0, 1, 0, 0, 0], [-2, 0, 2, 0, 1], [0, 0, 0, 0, -2], [0, 0, 0, 0, -1], [0, 0, 0, 0, 0],
        [0, 0, 0, 0, 1], [0, 0, 0, 0, 2], [-1, 0, 0, 1, 0], [0, -1, 0, 0, -1], [0, -1, 0, 0, 0], [0, 1, -2, 2, -2],
        [0, -1, 0, 0, 1], [-2, 0, 0, 2, 0], [-2, 0, 0, 2, 1], [0, 0, -2, 2, -2], [0, 0, -2, 2, -1], [0, -1, -2, 2, -2],
        [1, 0, 0, -2, 0], [1, 0, 0, -2, 1], [-1, 0, 0, 0, -1], [-1, 0, 0, 0, 0], [-1, 0, 0, 0, 1], [0, 0, 0, -2, 0],
        [-2, 0, 0, 0, 0], [0, 0, -2, 0, -2], [0, 0, -2, 0, -1], [0, 0, -2, 0, 0], [-1, 0, -2, 0, -2], [-1, 0, -2, 0, -1]
        ])

    # In-phase amplitude
    ip = np.array([-0.1, -0.1, -0.1, -0.7, -0.1, -1.3, -6.8, 0.1, 0.1, 0.1, 0.4, 1.3, 0.3, 0.3, 0.1, -1.9, 0.5, -43.4,
                   0.6, 1.6, 0.1, 0.1, -8.8, 470.9, 68.1, -1.6, 0.1, -0.1, -20.6, 0.3, -0.3, -0.2, -0.1, -5.0, 0.2,
                   -0.2, -0.5, -0.1, 0.1, -2.1, -0.4, -0.2, -0.1, -0.6, -0.4, -0.1, -0.1, -0.1])

    # Out-of-phase amplitude
    op = np.array([0, 0, 0, 0.1, 0, 0.1, 0.6, 0, 0, 0, 0, -0.1, 0, 0, 0, 0.1, 0, 2.9, 0, -0.1, 0, 0, 0.5, -30.2, -4.6,
                   0.1, 0, 0, -0.3, 0, 0, 0, 0, 0.3, 0, 0, 0, 0, 0, 0.1, 0, 0, 0, 0, 0, 0, 0, 0])

    # Units: 10**-12
    ip = ip * 10e-12
    op = op * 10e-12

    doodson = np.array([125.755, 127.555, 135.645, 135.655, 137.455, 145.545,
                        145.555, 147.555, 153.655, 155.445, 155.455, 155.655,
                        155.665, 157.455, 157.465, 162.556, 163.545, 163.555,
                        164.554, 164.556, 165.345, 165.535, 165.545, 165.555,
                        165.565, 165.575, 166.455, 166.544, 166.554, 166.556,
                        166.564, 167.355, 167.365, 167.555, 167.565, 168.554,
                        173.655, 173.665, 175.445, 175.455, 175.465, 183.555,
                        185.355, 185.555, 185.565, 185.575, 195.455, 195.465])

    return delaunay_multipliers, ip, op, doodson


cdef equation_68b_m2(double GMST, double[:] delaunay_variables):
    """
    Equation (6.8b) (with m=2) in IERS Conventions [2].
    """

    delaunay_multipliers, ip, _ = table_65c()
    normalization_factor = math.sqrt(5/12)

    sin_theta_f = np.zeros(delaunay_multipliers.shape[0])
    cos_theta_f = np.zeros(delaunay_multipliers.shape[0])

    for i in range(0, delaunay_multipliers.shape[0]):
        sin_theta_f[i] = math.sin(2*(GMST + math.pi) - np.dot(delaunay_multipliers[i], delaunay_variables))
        cos_theta_f[i] = math.cos(2*(GMST + math.pi) - np.dot(delaunay_multipliers[i], delaunay_variables))

    C_correction = normalization_factor*np.dot(cos_theta_f, ip)
    S_correction = -normalization_factor*np.dot(sin_theta_f, ip)

    return C_correction, S_correction



cdef table_65c():
    """Computation of a list of cos_theta_f and sin_theta_f for different frequencies f
    from Table (6.5c) in IERS Conventions.

    Returns:
        delaunay_multipliers: matrix of numbers to be multiplied with the Delaunay variables
        ip:                   vector of in-phase amplitudes
        op:                   vector of out-of-phase amplitudes

    """
    # Delauney multipliers
    delaunay_multipliers = np.matrix([[1, 0, 2, 0, 2], [0, 0, 2, 0, 2]])

    # In-phase amplitude
    ip = np.array([-0.3, -1.2])

    # Units: 10**-12
    ip = ip * 10e-12

    doodson = np.array([245.655, 255.555])

    return delaunay_multipliers, ip, doodson


cdef equation_69(n):
    """
    Equation (6.9) and table (6.4) with f_21 from table (6.8) in IERS Conventions [2].
    """
    if n == 2:
        L = np.array([0.29954 - (0.1412e-2) * 1j, -0.77896e-3 - (0.3711e-4) * 1j, 0.90963e-4 - (0.2963e-5) * 1j,
                      -0.11416e-5 + (0.5325e-7) * 1j])
    elif n == 4:
        L = np.array([-0.804e-3 + (0.237e-5) * 1j, 0.209e-5 + (0.103e-6) * 1j, -0.182e-6 + (0.650e-8) * 1j, -0.713e-9
                      - (0.33e-9) * 1j])
    else:
        L = np.zeros(4)

    f_21 = -0.695827
    k210 = L[0]
    sigma = f_21 / (15 * 1.002737909)
    sigma_alpha = np.array([-0.0026010 - 0.0001361 * 1j, 1.0023181 + 0.000025 * 1j, -1.999026 + 0.00078 * 1j])

    for i in range(1, 4):
        k210 += L[i] / (sigma - sigma_alpha[i - 1])

    return k210


cdef delaunay(double tt):
    """
    The Delaunay variables as function of time.

    Input:
        tt:  Time, in tt

    Returns:
        Five Delaunay variables, l, lprime, F, D, Omega, see section 5.7 in IERS Conventions [2] for their definition.
    """
    # Julian day for January 2000 1d 12h
    cdef double tt_2000 = 2451545.0
    
    # Time to be given in Julian centuries.
    cdef double t = (tt - tt_2000) / 36525

    cdef double l, lprime, F, D, Omega

    l = 134.96340251 + 1 / 3600 * (1717915923.2178 * t + 31.8792 * t**2 + 0.051635 * t**3 - 0.00024470 * t**4)
    lprime = 357.52910918 + 1 / 3600 * (129596581.0481 * t - 0.5532 * t**2 + 0.000136 * t**3 - 0.00001149 * t**4)
    F = 93.27209062 + 1 / 3600 * (1739527262.8478 * t - 12.7512 * t**2 - 0.001037 * t**3 + 0.00000417 * t**4)
    D = 297.85019547 + 1 / 3600 * (1602961601.2090 * t - 6.3706 * t**2 + 0.006593 * t**3 - 0.00003169 * t**4)
    Omega = 125.04455501 + 1 / 3600 * (-6962890.5431 * t + 7.4722 * t**2 + 0.007702 * t**3 - 0.00005939 * t**4)

    return np.array([math.radians(l), math.radians(lprime), math.radians(F), math.radians(D), math.radians(Omega)])


cdef normalization_factor(int n, int m):
    """
    Normalization factor, see Conventions chapter 6
    
    Input: 
        n:  Integer
        m:  Integer
    Returns 
       integer
    """
    return np.sqrt(math.factorial(n - m) * (2 * n + 1) * (2 - (m ==0)) / math.factorial(n + m))
