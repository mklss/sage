r"""
Arbitrary Precision Complex Balls using Arb

AUTHORS:

- Clemens Heuberger (2014-10-25): Initial version.

This is a binding to the `Arb library <http://fredrikj.net/arb/>`_; it
may be useful to refer to its documentation for more details.

Parts of the documentation for this module are copied or adapted from
Arb's own documentation, licenced under the GNU General Public License
version 2, or later.

.. SEEALSO::

    - :mod:`Real intervals using Arb <sage.rings.real_arb>`
    - :mod:`Complex interval field (using MPFI) <sage.rings.complex_interval_field>`
    - :mod:`Complex intervals (using MPFI) <sage.rings.complex_interval>`

Data Structure
==============

A :class:`ComplexBall` represents a complex number with error bounds. It wraps
an Arb object of type ``acb_t``, which  consists of a pair of real number balls
representing the real and imaginary part with separate error bounds.

A :class:`ComplexBall` thus represents a rectangle `[m_1-r_1, m_1+r_1] +
[m_2-r_2, m_2+r_2] i` in the complex plane. This is used in Arb instead of a
disk or square representation (consisting of a complex floating-point midpoint
with a single radius), since it allows implementing many operations more
conveniently by splitting into ball operations on the real and imaginary parts.
It also allows tracking when complex numbers have an exact (for example exactly
zero) real part and an inexact imaginary part, or vice versa.

Comparison
==========

.. WARNING::

    Identical :class:`ComplexBall` objects are understood to give
    permission for algebraic simplification. This assumption is made
    to improve performance. For example, setting ``z = x*x`` sets `z`
    to a ball enclosing the set `\{t^2 : t \in x\}` and not the
    (generally larger) set `\{tu : t \in x, u \in x\}`.

Two elements are equal if and only if they are the same object
or if both are exact and equal::

    sage: from sage.rings.complex_ball_acb import CBF
    doctest:...: FutureWarning: This class/method/function is marked as experimental.
    It, its functionality or its interface might change without a formal deprecation.
    See http://trac.sagemath.org/17218 for details.
    sage: a = CBF(1, 2)
    sage: b = CBF(1, 2)
    sage: a is b
    False
    sage: a == b
    True
    sage: a = CBF(1/3, 1/5)
    sage: b = CBF(1/3, 1/5)
    sage: a.is_exact()
    False
    sage: b.is_exact()
    False
    sage: a is b
    False
    sage: a == b
    False

A ball is non-zero if and only if it does not contain zero. ::

    sage: a = CBF(RIF(-0.5, 0.5))
    sage: bool(a)
    False
    sage: a != 0
    False
    sage: b = CBF(1/3, 1/5)
    sage: bool(b)
    True
    sage: b != 0
    True

Coercion
========

Automatic coercions work as expected::

    sage: from sage.rings.real_arb import RealBallField
    sage: bpol = 1/3*CBF(i) + AA(sqrt(2)) + (polygen(RealBallField(20), 'x') + QQbar(i))
    sage: bpol
    x + [1.41421 +/- 5.09e-6] + [1.33333 +/- 3.97e-6]*I
    sage: bpol.parent()
    Univariate Polynomial Ring in x over Complex ball field with 20 bits precision

Classes and Methods
===================
"""
#*****************************************************************************
# Copyright (C) 2014 Clemens Heuberger <clemens.heuberger@aau.at>
#
#  Distributed under the terms of the GNU General Public License (GPL)
#  as published by the Free Software Foundation; either version 2 of
#  the License, or (at your option) any later version.
#                http://www.gnu.org/licenses/
#*****************************************************************************
include 'sage/ext/interrupt.pxi'
include "sage/ext/python.pxi"
include "sage/ext/stdsage.pxi"

import operator

import sage.categories.fields

cimport sage.rings.integer
cimport sage.rings.rational

from sage.libs.arb.arb cimport *
from sage.libs.arb.acb cimport *
from sage.libs.arb.acb_hypgeom cimport *
from sage.libs.arb.arf cimport arf_t, arf_init, arf_get_mpfr, arf_set_mpfr, arf_clear, arf_set_mag, arf_set
from sage.libs.arb.mag cimport mag_t, mag_init, mag_clear, mag_add, mag_set_d, MAG_BITS, mag_is_inf, mag_is_finite, mag_zero
from sage.libs.flint.fmpz cimport fmpz_t, fmpz_init, fmpz_get_mpz, fmpz_set_mpz, fmpz_clear
from sage.libs.flint.fmpq cimport fmpq_t, fmpq_init, fmpq_set_mpq, fmpq_clear
from sage.libs.gmp.mpz cimport mpz_fits_ulong_p, mpz_fits_slong_p, mpz_get_ui, mpz_get_si
from sage.misc.superseded import experimental
from sage.rings.complex_field import ComplexField
from sage.rings.complex_interval_field import ComplexIntervalField
from sage.rings.integer_ring import ZZ
from sage.rings.real_arb cimport mpfi_to_arb, arb_to_mpfi
from sage.rings.real_arb import RealBallField
from sage.structure.element cimport Element, ModuleElement
from sage.structure.parent cimport Parent
from sage.structure.unique_representation import UniqueRepresentation

cdef inline bint acb_is_nonzero(const acb_t z):
    return arb_is_nonzero(&z.real) or arb_is_nonzero(&z.imag)

cdef void ComplexIntervalFieldElement_to_acb(
    acb_t target,
    ComplexIntervalFieldElement source):
    """
    Convert a :class:`ComplexIntervalFieldElement` to an ``acb``.

    INPUT:

    - ``target`` -- an ``acb_t``

    - ``source`` -- a :class:`ComplexIntervalFieldElement`

    OUTPUT:

    None.
    """
    cdef long precision
    precision = source.parent().precision()
    mpfi_to_arb(&target.real, source.__re, precision)
    mpfi_to_arb(&target.imag, source.__im, precision)

cdef int acb_to_ComplexIntervalFieldElement(
    ComplexIntervalFieldElement target,
    const acb_t source) except -1:
    """
    Convert an ``acb`` to a :class:`ComplexIntervalFieldElement`.

    INPUT:

    - ``target`` -- a :class:`ComplexIntervalFieldElement`

    - ``source`` -- an ``acb_t``

    OUTPUT:

    A :class:`ComplexIntervalFieldElement`.
    """
    cdef long precision = target._prec

    arb_to_mpfi(target.__re, &source.real, precision)
    arb_to_mpfi(target.__im, &source.imag, precision)
    return 0

class ComplexBallField(UniqueRepresentation, Parent):
    r"""
    An approximation of the field of complex numbers using pairs of mid-rad
    intervals.

    INPUT:

    - ``precision`` -- an integer `\ge 2`.

    EXAMPLES::

        sage: from sage.rings.complex_ball_acb import ComplexBallField
        sage: CBF = ComplexBallField() # indirect doctest
        sage: CBF(1)
        1.000000000000000

    TESTS::

        sage: ComplexBallField(0)
        Traceback (most recent call last):
        ...
        ValueError: Precision must be at least 2.
        sage: ComplexBallField(1)
        Traceback (most recent call last):
        ...
        ValueError: Precision must be at least 2.
    """
    Element = ComplexBall

    @staticmethod
    def __classcall__(cls, long precision=53, category=None):
        r"""
        Normalize the arguments for caching.

        TESTS::

            sage: from sage.rings.complex_ball_acb import ComplexBallField
            sage: ComplexBallField(53) is ComplexBallField()
            True
        """
        return super(ComplexBallField, cls).__classcall__(cls, precision, category)

    @experimental(17218)
    def __init__(self, precision, category):
        r"""
        Initialize the complex ball field.

        INPUT:

        - ``precision`` -- an integer `\ge 2`.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import ComplexBallField
            sage: CBF = ComplexBallField()
            sage: CBF(1)
            1.000000000000000

        TESTS::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF.base()
            Real ball field with 53 bits precision
            sage: CBF.base_ring()
            Real ball field with 53 bits precision

        There are direct coercions from ZZ and QQ (for which arb provides
        construction functions)::

            sage: CBF.coerce_map_from(ZZ)
            Conversion map:
            From: Integer Ring
            To:   Complex ball field with 53 bits precision
            sage: CBF.coerce_map_from(QQ)
            Conversion map:
            From: Rational Field
            To:   Complex ball field with 53 bits precision

        Various other coercions are available through real ball fields or CLF::

            sage: CBF.coerce_map_from(RLF)
            Composite map:
            From: Real Lazy Field
            To:   Complex ball field with 53 bits precision
            Defn:   Conversion map:
                    From: Real Lazy Field
                    To:   Real ball field with 53 bits precision
                    then
                    Conversion map:
                    From: Real ball field with 53 bits precision
                    To:   Complex ball field with 53 bits precision
            sage: CBF.has_coerce_map_from(AA)
            True
            sage: CBF.has_coerce_map_from(QuadraticField(-1))
            True
            sage: CBF.has_coerce_map_from(QQbar)
            True
            sage: CBF.has_coerce_map_from(CLF)
            True
        """
        if precision < 2:
            raise ValueError("Precision must be at least 2.")
        real_field = RealBallField(precision)
        super(ComplexBallField, self).__init__(
                base=real_field,
                category=category or [sage.categories.fields.Fields()])
        self._prec = precision
        from sage.rings.rational_field import QQ
        from sage.rings.real_lazy import CLF
        self._populate_coercion_lists_([ZZ, QQ, real_field, CLF])

    def _real_field(self):
        """
        TESTS::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF._real_field()
            Real ball field with 53 bits precision
        """
        return self._base

    def _repr_(self):
        r"""
        String representation of ``self``.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import ComplexBallField
            sage: ComplexBallField()
            Complex ball field with 53 bits precision
            sage: ComplexBallField(106)
            Complex ball field with 106 bits precision
        """
        return "Complex ball field with {} bits precision".format(self._prec)

    def construction(self):
        """
        Return the construction of a complex ball field as the algebraic
        closure of the real ball field with the same precision.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: functor, base = CBF.construction()
            sage: functor, base
            (AlgebraicClosureFunctor, Real ball field with 53 bits precision)
            sage: functor(base) is CBF
            True
        """
        from sage.categories.pushout import AlgebraicClosureFunctor
        return (AlgebraicClosureFunctor(), self._base)

    def ngens(self):
        r"""
        Return 1 as the only generator is the imaginary unit.

        EXAMPLE::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF.ngens()
            1
        """
        return 1

    def gen(self, i):
        r"""
        For i = 0, return the imaginary unit in this complex ball field.

        EXAMPLE::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF.0
            1.000000000000000*I
            sage: CBF.gen(1)
            Traceback (most recent call last):
            ...
            ValueError: only one generator
        """
        if i == 0:
            return self(0, 1)
        else:
            raise ValueError("only one generator")

    def gens(self):
        r"""
        Return the tuple of generators of this complex ball field, i.e.
        ``(i,)``.

        EXAMPLE::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF.gens()
            (1.000000000000000*I,)
            sage: CBF.gens_dict()
            {'1.000000000000000*I': 1.000000000000000*I}
        """
        return (self(0, 1),)

    def _coerce_map_from_(self, other):
        r"""
        Parents that canonically coerce into complex ball fields include:

        - anything that coerces into the corresponding real ball field;

        - real and complex ball fields with a larger precision;

        - various exact or lazy parents representing subsets of the complex
          numbers, such as ``QQbar``, ``CLF``, and number fields equipped
          with complex embeddings.

        TESTS::

            sage: from sage.rings.complex_ball_acb import CBF, ComplexBallField
            sage: from sage.rings.real_arb import RBF, RealBallField
            sage: CBF.coerce_map_from(CBF)
            Identity endomorphism of Complex ball field with 53 bits precision
            sage: CBF.coerce_map_from(ComplexBallField(100))
            Conversion map:
            From: Complex ball field with 100 bits precision
            To:   Complex ball field with 53 bits precision
            sage: CBF.has_coerce_map_from(ComplexBallField(42))
            False
            sage: CBF.has_coerce_map_from(RealBallField(54))
            True
            sage: CBF.has_coerce_map_from(RealBallField(52))
            False

        Check that there are no coercions from interval or floating-point parents::

            sage: CBF.has_coerce_map_from(RIF)
            False
            sage: CBF.has_coerce_map_from(CIF)
            False
            sage: CBF.has_coerce_map_from(RR)
            False
            sage: CBF.has_coerce_map_from(CC)
            False
        """
        if isinstance(other, (RealBallField, ComplexBallField)):
            return (other._prec >= self._prec)

    def _element_constructor_(self, x=None, y=None):
        r"""
        Convert (x, y) to an element of this complex ball field, perhaps
        non-canonically.

        INPUT:

        - ``x``, ``y`` (optional) -- either a complex number, interval or ball,
          or two real ones (see examples below for more information on accepted
          number types).

        .. SEEALSO:: :meth:`sage.rings.real_arb.RealBallField._element_constructor_`

        EXAMPLES::

            sage: from sage.rings.real_arb import RBF
            sage: from sage.rings.complex_ball_acb import CBF, ComplexBallField
            sage: CBF()
            0
            sage: CBF(1) # indirect doctest
            1.000000000000000
            sage: CBF(1, 1)
            1.000000000000000 + 1.000000000000000*I
            sage: CBF(pi, sqrt(2))
            [3.141592653589793 +/- 5.61e-16] + [1.414213562373095 +/- 4.10e-16]*I
            sage: CBF(I)
            1.000000000000000*I
            sage: CBF(pi+I/3)
            [3.141592653589793 +/- 5.61e-16] + [0.3333333333333333 +/- 7.04e-17]*I
            sage: CBF(QQbar(i/7))
            [0.1428571428571428 +/- 9.09e-17]*I
            sage: CBF(AA(sqrt(2)))
            [1.414213562373095 +/- 4.10e-16]
            sage: CBF(CIF(0, 1))
            1.000000000000000*I
            sage: CBF(RBF(1/3))
            [0.3333333333333333 +/- 7.04e-17]
            sage: CBF(RBF(1/3), RBF(1/6))
            [0.3333333333333333 +/- 7.04e-17] + [0.1666666666666667 +/- 7.04e-17]*I
            sage: CBF(1/3)
            [0.3333333333333333 +/- 7.04e-17]
            sage: CBF(1/3, 1/6)
            [0.3333333333333333 +/- 7.04e-17] + [0.1666666666666667 +/- 7.04e-17]*I
            sage: ComplexBallField(106)(1/3, 1/6)
            [0.33333333333333333333333333333333 +/- 6.94e-33] + [0.16666666666666666666666666666666 +/- 7.70e-33]*I
            sage: CBF(infinity, NaN)
            [+/- inf] + nan*I
            sage: CBF(x)
            Traceback (most recent call last):
            ...
            TypeError: unable to convert x to a ComplexBall

        TESTS::

            sage: CBF(1+I, 2)
            Traceback (most recent call last):
            ...
            TypeError: unable to convert I + 1 to a RealBall
        """
        try:
            return self.element_class(self, x, y)
        except TypeError:
            pass

        if y is None:
            try:
                x = self._base(x)
                return self.element_class(self, x)
            except (TypeError, ValueError):
                pass
            try:
                y = self._base(x.imag())
                x = self._base(x.real())
                return self.element_class(self, x, y)
            except (AttributeError, TypeError):
                pass
            try:
                x = ComplexIntervalField(self._prec)(x)
                return self.element_class(self, x)
            except TypeError:
                pass
            raise TypeError("unable to convert {} to a ComplexBall".format(x))
        else:
            x = self._base(x)
            y = self._base(y)
            return self.element_class(self, x, y)

    def _an_element_(self):
        r"""
        Construct an element.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF.an_element() # indirect doctest
            [0.3333333333333333 +/- 1.49e-17] - [0.1666666666666667 +/- 4.26e-17]*I
        """
        return self(1.0/3, -1.0/6)

    def precision(self):
        """
        Return the bit precision used for operations on elements of this field.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import ComplexBallField
            sage: ComplexBallField().precision()
            53
        """
        return self._prec

    def is_exact(self):
        """
        Complex ball fields are not exact.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import ComplexBallField
            sage: ComplexBallField().is_exact()
            False
        """
        return False

    def is_finite(self):
        """
        Complex ball fields are infinite.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import ComplexBallField
            sage: ComplexBallField().is_finite()
            False
        """
        return False

    def characteristic(self):
        """
        Complex ball fields have characteristic zero.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import ComplexBallField
            sage: ComplexBallField().characteristic()
            0
        """
        return 0

    def some_elements(self):
        """
        Complex ball fields contain elements with exact, inexact, infinite, or
        undefined real and imaginary parts.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF.some_elements()
            [1.000000000000000,
             -0.5000000000000000*I,
             1.000000000000000 + [0.3333333333333333 +/- 1.49e-17]*I,
             [-0.3333333333333333 +/- 1.49e-17] + 0.2500000000000000*I,
             [-2.175556475109056e+181961467118333366510562 +/- 1.29e+181961467118333366510545],
             [+/- inf],
             [0.3333333333333333 +/- 1.49e-17] + [+/- inf]*I,
             [+/- inf] + [+/- inf]*I,
             nan,
             nan + nan*I,
             [+/- inf] + nan*I]
        """
        return [self(1), self(0, -1./2), self(1, 1./3), self(-1./3, 1./4),
                -self(1, 1)**(sage.rings.integer.Integer(2)**80),
                self('inf'), self(1./3, 'inf'), self('inf', 'inf'),
                self('nan'), self('nan', 'nan'), self('inf', 'nan')]

cdef inline bint _do_sig(long prec):
    """
    Whether signal handlers should be installed for calls to arb.

    TESTS::

        sage: from sage.rings.complex_ball_acb import ComplexBallField
    """
    return (prec > 1000)

cdef inline long prec(ComplexBall ball):
    return ball._parent._prec

cdef inline Parent real_ball_field(ComplexBall ball):
    return ball._parent._base

cdef class ComplexBall(RingElement):
    """
    Hold one ``acb_t`` of the `Arb library
    <http://fredrikj.net/arb/>`_

    EXAMPLES::

        sage: from sage.rings.complex_ball_acb import ComplexBallField
        sage: a = ComplexBallField()(1, 1)
        sage: a
        1.000000000000000 + 1.000000000000000*I
    """
    def __cinit__(self):
        """
        Allocate memory for the encapsulated value.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import ComplexBallField
            sage: ComplexBallField(2)(0) # indirect doctest
            0
        """
        acb_init(self.value)

    def __dealloc__(self):
        """
        Deallocate memory of the encapsulated value.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import ComplexBallField
            sage: a = ComplexBallField(2)(0) # indirect doctest
            sage: del a
        """
        acb_clear(self.value)

    def __init__(self, parent, x=None, y=None):
        """
        Initialize the :class:`ComplexBall`.

        INPUT:

        - ``parent`` -- a :class:`ComplexBallField`.

        - ``x``, ``y`` (optional) -- either a complex number, interval or ball,
          or two real ones.

        .. SEEALSO:: :meth:`ComplexBallField._element_constructor_`

        TESTS::

            sage: from sage.rings.complex_ball_acb import ComplexBallField, ComplexBall
            sage: from sage.rings.real_arb import RBF
            sage: CBF53, CBF100 = ComplexBallField(53), ComplexBallField(100)
            sage: ComplexBall(CBF100)
            0
            sage: ComplexBall(CBF100, ComplexBall(CBF53, ComplexBall(CBF100, 1/3)))
            [0.333333333333333333333333333333 +/- 4.65e-31]
            sage: ComplexBall(CBF100, RBF(pi))
            [3.141592653589793 +/- 5.61e-16]
            sage: ComplexBall(CBF100, -3r)
            -3.000000000000000000000000000000
            sage: ComplexBall(CBF100, 10^100)
            1.000000000000000000000000000000e+100
            sage: ComplexBall(CBF100, CIF(1, 2))
            1.000000000000000000000000000000 + 2.000000000000000000000000000000*I
            sage: ComplexBall(CBF100, RBF(1/3), RBF(1))
            [0.3333333333333333 +/- 7.04e-17] + 1.000000000000000000000000000000*I
            sage: ComplexBall(CBF100, 1, 2)
            Traceback (most recent call last):
            ...
            TypeError: unsupported initializer
        """
        cdef fmpz_t tmpz
        cdef fmpq_t tmpq

        RingElement.__init__(self, parent)

        if x is None:
            return
        elif y is None:
            if isinstance(x, ComplexBall):
                acb_set(self.value, (<ComplexBall> x).value)
            elif isinstance(x, RealBall):
                acb_set_arb(self.value, (<RealBall> x).value)
            elif isinstance(x, int):
                acb_set_si(self.value, PyInt_AS_LONG(x))
            elif isinstance(x, sage.rings.integer.Integer):
                if _do_sig(prec(self)): sig_on()
                fmpz_init(tmpz)
                fmpz_set_mpz(tmpz, (<sage.rings.integer.Integer> x).value)
                acb_set_fmpz(self.value, tmpz)
                fmpz_clear(tmpz)
                if _do_sig(prec(self)): sig_off()
            elif isinstance(x, sage.rings.rational.Rational):
                if _do_sig(prec(self)): sig_on()
                fmpq_init(tmpq)
                fmpq_set_mpq(tmpq, (<sage.rings.rational.Rational> x).value)
                acb_set_fmpq(self.value, tmpq, prec(self))
                fmpq_clear(tmpq)
                if _do_sig(prec(self)): sig_off()
            elif isinstance(x, ComplexIntervalFieldElement):
                ComplexIntervalFieldElement_to_acb(self.value,
                                                   <ComplexIntervalFieldElement> x)
            else:
                raise TypeError("unsupported initializer")
        elif isinstance(x, RealBall) and isinstance(y, RealBall):
            arb_set(acb_realref(self.value), (<RealBall> x).value)
            arb_set(acb_imagref(self.value), (<RealBall> y).value)
        else:
            raise TypeError("unsupported initializer")

    cdef ComplexBall _new(self):
        """
        Return a new complex ball element with the same parent as ``self``.
        """
        cdef ComplexBall x
        x = ComplexBall.__new__(ComplexBall)
        x._parent = self._parent
        return x

    def _repr_(self):
        """
        Return a string representation of ``self``.

        OUTPUT:

        A string.

        EXAMPLES::

           sage: from sage.rings.complex_ball_acb import CBF
           sage: CBF(1/3)
           [0.3333333333333333 +/- 7.04e-17]
           sage: CBF(0, 1/3)
           [0.3333333333333333 +/- 7.04e-17]*I
           sage: CBF(1/3, 1/6)
           [0.3333333333333333 +/- 7.04e-17] + [0.1666666666666667 +/- 7.04e-17]*I

        TESTS::

           sage: CBF(1-I/2)
           1.000000000000000 - 0.5000000000000000*I
        """
        cdef arb_t real = acb_realref(self.value)
        cdef arb_t imag = acb_imagref(self.value)
        if arb_is_zero(imag):
            return self.real()._repr_()
        elif arb_is_zero(real):
            return "{}*I".format(self.imag()._repr_())
        elif arb_is_exact(imag) and arb_is_negative(imag):
            return "{} - {}*I".format(self.real()._repr_(),
                                        (-self.imag())._repr_())
        else:
            return "{} + {}*I".format(self.real()._repr_(),
                                        self.imag()._repr_())

    # Conversions

    cpdef ComplexIntervalFieldElement _complex_mpfi_(self, parent):
        """
        Return :class:`ComplexIntervalFieldElement` of the same value.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CIF(CBF(1/3, 1/3)) # indirect doctest
            0.3333333333333333? + 0.3333333333333333?*I
        """
        cdef ComplexIntervalFieldElement res = parent.zero()
        res = res._new() # FIXME after modernizing CIF
        acb_to_ComplexIntervalFieldElement(res, self.value)
        return res

    def _integer_(self, _):
        """
        Check that this ball contains a single integer and return that integer.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: from sage.rings.real_arb import RBF
            sage: ZZ(CBF(-42, RBF(.1, rad=.2))) # indirect doctest
            -42
            sage: ZZ(CBF(i))
            Traceback (most recent call last):
            ...
            ValueError: 1.000000000000000*I does not contain a unique integer
        """
        cdef sage.rings.integer.Integer res
        cdef fmpz_t tmp
        fmpz_init(tmp)
        try:
            if acb_get_unique_fmpz(tmp, self.value):
                res = sage.rings.integer.Integer.__new__(sage.rings.integer.Integer)
                fmpz_get_mpz(res.value, tmp)
            else:
                raise ValueError("{} does not contain a unique integer".format(self))
        finally:
            fmpz_clear(tmp)
        return res

    def _rational_(self):
        """
        Check that this ball contains a single rational number and return that
        number.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: QQ(CBF(12345/2^5))
            12345/32
            sage: QQ(CBF(i))
            Traceback (most recent call last):
            ...
            ValueError: 1.000000000000000*I does not contain a unique rational number
        """
        if acb_is_real(self.value) and acb_is_exact(self.value):
            return self.real().mid().exact_rational()
        else:
            raise ValueError("{} does not contain a unique rational number".format(self))

    def _complex_mpfr_field_(self, parent):
        r"""
        Convert this complex ball to a complex number.

        INPUT:

        - ``parent`` - :class:`~sage.rings.complex_field.ComplexField_class`,
          target parent.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CC(CBF(1/3, 1/3))
            0.333333333333333 + 0.333333333333333*I
            sage: ComplexField(100)(CBF(1/3, 1/3))
            0.33333333333333331482961625625 + 0.33333333333333331482961625625*I
        """
        real_field = parent._base
        return parent(real_field(self.real()), real_field(self.imag()))

    def _real_mpfi_(self, parent):
        r"""
        Try to convert this complex ball to a real interval.

        Fail if the imaginary part is not exactly zero.

        INPUT:

        - ``parent`` - :class:`~sage.rings.real_mpfi.RealIntervalField_class`,
          target parent.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: from sage.rings.real_arb import RBF
            sage: RIF(CBF(RBF(1/3, rad=1e-5)))
            0.3334?
            sage: RIF(CBF(RBF(1/3, rad=1e-5), 1e-10))
            Traceback (most recent call last):
            ...
            ValueError: nonzero imaginary part
        """
        if acb_is_real(self.value):
            return parent(self.real())
        else:
            raise ValueError("nonzero imaginary part")

    def _mpfr_(self, parent):
        r"""
        Try to convert this complex ball to a real number.

        Fail if the imaginary part is not exactly zero.

        INPUT:

        - ``parent`` - :class:`~sage.rings.real_mpfr.RealField_class`,
          target parent.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: RR(CBF(1/3))
            0.333333333333333
            sage: RR(CBF(1, 1/3) - CBF(0, 1/3))
            Traceback (most recent call last):
            ...
            ValueError: nonzero imaginary part
        """
        if acb_is_real(self.value):
            return parent(self.real())
        else:
            raise ValueError("nonzero imaginary part")

    # Real and imaginary part, midpoint

    cpdef RealBall real(self):
        """
        Return the real part of this ball.

        OUTPUT:

        A :class:`RealBall`.

        EXAMPLES::

           sage: from sage.rings.complex_ball_acb import ComplexBallField
           sage: CBF = ComplexBallField()
           sage: a = CBF(1/3, 1/5)
           sage: a.real()
           [0.3333333333333333 +/- 7.04e-17]
        """
        cdef RealBall r = RealBall(real_ball_field(self))
        arb_set(r.value, acb_realref(self.value))
        return r

    cpdef RealBall imag(self):
        """
        Return the imaginary part of this ball.

        OUTPUT:

        A :class:`RealBall`.

        EXAMPLES::

           sage: from sage.rings.complex_ball_acb import ComplexBallField
           sage: CBF = ComplexBallField()
           sage: a = CBF(1/3, 1/5)
           sage: a.imag()
           [0.2000000000000000 +/- 4.45e-17]
        """
        cdef RealBall r = RealBall(real_ball_field(self))
        arb_set(r.value, acb_imagref(self.value))
        return r

    def abs(self):
        """
        Return the absolute value of this complex ball.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(1 + i).abs()
            [1.414213562373095 +/- 2.99e-16]
            sage: CBF(1 + i).abs().parent()
            Real ball field with 53 bits precision
        """
        cdef RealBall r = RealBall(real_ball_field(self))
        acb_abs(r.value, self.value, prec(self))
        return r

    def below_abs(self, test_zero=False):
        """
        Return a lower bound for the absolute value of this complex ball.

        INPUT:

        - ``test_zero`` (boolean, default ``False``) -- if ``True``,
          make sure that the returned lower bound is positive, raising
          an error if the ball contains zero.

        .. SEEALSO:: :meth:`abs`, :meth:`above_abs`

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import ComplexBallField, CBF
            sage: b = ComplexBallField(8)(1+i).below_abs()
            sage: b
            [1.4 +/- 0.0141]
            sage: b.is_exact()
            True
            sage: QQ(b)*128
            181
            sage: (CBF(1/3) - 1/3).below_abs()
            0
            sage: (CBF(1/3) - 1/3).below_abs(test_zero=True)
            Traceback (most recent call last):
            ...
            ValueError: ball contains zero
        """
        cdef RealBall res = RealBall(real_ball_field(self))
        acb_get_abs_lbound_arf(arb_midref(res.value), self.value, prec(self))
        if test_zero and arb_contains_zero(res.value):
            assert acb_contains_zero(self.value)
            raise ValueError("ball contains zero")
        return res

    def above_abs(self):
        """
        Return an upper bound for the absolute value of this complex ball.

        .. SEEALSO:: :meth:`abs`, :meth:`below_abs`

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import ComplexBallField
            sage: b = ComplexBallField(8)(1+i).above_abs()
            sage: b
            [1.4 +/- 0.0219]
            sage: b.is_exact()
            True
            sage: QQ(b)*128
            182
        """
        cdef RealBall res = RealBall(real_ball_field(self))
        acb_get_abs_ubound_arf(arb_midref(res.value), self.value, prec(self))
        return res

    def arg(self):
        """
        Return the argument of this complex ball.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(1 + i).arg()
            [0.785398163397448 +/- 3.91e-16]
            sage: CBF(-1).arg()
            [3.141592653589793 +/- 5.61e-16]
            sage: CBF(-1).arg().parent()
            Real ball field with 53 bits precision
        """
        cdef RealBall r = RealBall(real_ball_field(self))
        acb_arg(r.value, self.value, prec(self))
        return r

    def mid(self):
        """
        Return the midpoint of this ball.

        OUTPUT:

        :class:`~sage.rings.complex_number.ComplexNumber`, floating-point
        complex number formed by the centers of the real and imaginary parts of
        this ball.

        .. SEEALSO:: :meth:`squash`

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(1/3, 1).mid()
            0.333333333333333 + 1.00000000000000*I
            sage: CBF(1/3, 1).mid().parent()
            Complex Field with 53 bits of precision
            sage: CBF('inf', 'nan').mid()
            +infinity - NaN*I
            sage: CBF('nan', 'inf').mid()
            NaN + +infinity*I
            sage: CBF('nan').mid()
            NaN
            sage: CBF('inf').mid()
            +infinity
            sage: CBF(0, 'inf').mid()
            +infinity*I
        """
        re, im = self.real().mid(), self.imag().mid()
        field = ComplexField(max(prec(self), re.prec(), im.prec()))
        return field(re, im)

    def squash(self):
        """
        Return an exact ball with the same midpoint as this ball.

        OUTPUT:

        A :class:`ComplexBall`.

        .. SEEALSO:: :meth:`mid`

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: mid = CBF(1/3, 1/10).squash()
            sage: mid
            [0.3333333333333333 +/- 1.49e-17] + [0.09999999999999999 +/- 1.68e-18]*I
            sage: mid.parent()
            Complex ball field with 53 bits precision
            sage: mid.is_exact()
            True
        """
        cdef ComplexBall res = self._new()
        arf_set(arb_midref(acb_realref(res.value)), arb_midref(acb_realref(self.value)))
        arf_set(arb_midref(acb_imagref(res.value)), arb_midref(acb_imagref(self.value)))
        mag_zero(arb_radref(acb_realref(res.value)))
        mag_zero(arb_radref(acb_imagref(res.value)))
        return res

    # Precision

    def round(self):
        """
        Return a copy of this ball rounded to the precision of the parent.

        .. SEEALSO:: :meth:`trim`

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: b = CBF(exp(I*pi/3).n(100))
            sage: b.mid()
            0.50000000000000000000000000000 + 0.86602540378443864676372317075*I
            sage: b.round().mid()
            0.500000000000000 + 0.866025403784439*I
        """
        cdef ComplexBall res = self._new()
        if _do_sig(prec(self)): sig_on()
        acb_set_round(res.value, self.value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return res

    def accuracy(self):
        """
        Return the effective relative accuracy of this ball measured in bits.

        This is computed as if calling
        :meth:`~sage.rings.real_arb.RealBall.accuracy()`
        on the real ball whose midpoint is the larger out of the real and
        imaginary midpoints of this complex ball, and whose radius is the
        larger out of the real and imaginary radii of this complex ball.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(exp(I*pi/3)).accuracy()
            51
            sage: CBF(I/2).accuracy() == CBF.base().maximal_accuracy()
            True
            sage: CBF('nan', 'inf').accuracy() == -CBF.base().maximal_accuracy()
            True

        .. seealso::

            :meth:`~sage.rings.real_arb.RealBallField.maximal_accuracy`
        """
        return acb_rel_accuracy_bits(self.value)

    def trim(self):
        """
        Return a trimmed copy of this ball.

        Return a copy of this ball with both the real and imaginary parts
        trimmed (see :meth:`~sage.rings.real_arb.RealBall.trim()`).

        .. SEEALSO:: :meth:`round`

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: from sage.rings.real_arb import RBF
            sage: b = CBF(1/3, RBF(1/3, rad=.01))
            sage: b.mid()
            0.333333333333333 + 0.333333333333333*I
            sage: b.trim().mid()
            0.333333333333333 + 0.333333015441895*I

        """
        cdef ComplexBall res = self._new()
        if _do_sig(prec(self)): sig_on()
        acb_trim(res.value, self.value)
        if _do_sig(prec(self)): sig_off()
        return res

    # Comparisons and predicates

    def is_zero(self):
        """
        Return ``True`` iff the midpoint and radius of this ball are both zero.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import ComplexBallField
            sage: CBF = ComplexBallField()
            sage: CBF(0).is_zero()
            True
            sage: CBF(RIF(-0.5, 0.5)).is_zero()
            False
        """
        return acb_is_zero(self.value)

    def __nonzero__(self):
        """
        Return ``True`` iff zero is not contained in the interval represented
        by this ball.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import ComplexBallField
            sage: CBF = ComplexBallField()
            sage: bool(CBF(pi, 1/3))
            True
            sage: bool(CBF(RIF(-0.5, 0.5), 1/3))
            True
            sage: bool(CBF(1/3, RIF(-0.5, 0.5)))
            True
            sage: bool(CBF(RIF(-0.5, 0.5), RIF(-0.5, 0.5)))
            False
        """
        return acb_is_nonzero(self.value)

    def is_exact(self):
        """
        Return ``True`` iff the radius of this ball is zero.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import ComplexBallField
            sage: CBF = ComplexBallField()
            sage: CBF(1).is_exact()
            True
            sage: CBF(1/3, 1/3).is_exact()
            False
        """
        return acb_is_exact(self.value)

    def is_real(self):
        """
        Return ``True`` iff the imaginary part of this ball is exactly zero.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(1/3, 0).is_real()
            True
            sage: (CBF(i/3) - CBF(1, 1/3)).is_real()
            False
            sage: CBF('inf').is_real()
            True
        """
        return acb_is_real(self.value)

    cpdef _richcmp_(left, Element right, int op):
        """
        Compare ``left`` and ``right``.

        For more information, see :mod:`sage.rings.complex_ball_acb`.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import ComplexBallField
            sage: CBF = ComplexBallField()
            sage: a = CBF(1)
            sage: b = CBF(1)
            sage: a is b
            False
            sage: a == b
            True
            sage: a = CBF(1/3)
            sage: a.is_exact()
            False
            sage: b = CBF(1/3)
            sage: b.is_exact()
            False
            sage: a == b
            False
            sage: a = CBF(1, 2)
            sage: b = CBF(1, 2)
            sage: a is b
            False
            sage: a == b
            True

        TESTS:

        Balls whose intersection consists of one point::

            sage: a = CBF(RIF(1, 2), RIF(1, 2))
            sage: b = CBF(RIF(2, 4), RIF(2, 4))
            sage: a < b
            Traceback (most recent call last):
            ...
            TypeError: No order is defined for ComplexBalls.
            sage: a > b
            Traceback (most recent call last):
            ...
            TypeError: No order is defined for ComplexBalls.
            sage: a <= b
            Traceback (most recent call last):
            ...
            TypeError: No order is defined for ComplexBalls.
            sage: a >= b
            Traceback (most recent call last):
            ...
            TypeError: No order is defined for ComplexBalls.
            sage: a == b
            False
            sage: a != b
            False

        Balls with non-trivial intersection::

            sage: a = CBF(RIF(1, 4), RIF(1, 4))
            sage: a = CBF(RIF(2, 5), RIF(2, 5))
            sage: a == b
            False
            sage: a != b
            False

        One ball contained in another::

            sage: a = CBF(RIF(1, 4), RIF(1, 4))
            sage: b = CBF(RIF(2, 3), RIF(2, 3))
            sage: a == b
            False
            sage: a != b
            False

        Disjoint balls::

            sage: a = CBF(1/3, 1/3)
            sage: b = CBF(1/5, 1/5)
            sage: a == b
            False
            sage: a != b
            True

        Exact elements::

            sage: a = CBF(2, 2)
            sage: b = CBF(2, 2)
            sage: a.is_exact()
            True
            sage: b.is_exact()
            True
            sage: a == b
            True
            sage: a != b
            False
        """
        cdef ComplexBall lt, rt
        cdef acb_t difference

        lt = left
        rt = right

        if op == Py_EQ:
            return lt is rt or (
                acb_is_exact(lt.value) and acb_is_exact(rt.value)
                and acb_equal(lt.value, rt.value))

        if op == Py_NE:
            return not acb_overlaps(lt.value, rt.value)

        elif op == Py_GT or op == Py_GE or op == Py_LT or op == Py_LE:
            raise TypeError("No order is defined for ComplexBalls.")

    def identical(self, ComplexBall other):
        """
        Return whether ``self`` and ``other`` represent the same ball.

        INPUT:

        - ``other`` -- a :class:`ComplexBall`.

        OUTPUT:

        Return True iff ``self`` and ``other`` are equal as sets, i.e. if their
        real and imaginary parts each have the same midpoint and radius.

        Note that this is not the same thing as testing whether both ``self``
        and ``other`` certainly represent the complex real number, unless
        either ``self`` or ``other`` is exact (and neither contains NaN). To
        test whether both operands might represent the same mathematical
        quantity, use :meth:`overlaps` or ``in``, depending on the
        circumstance.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(1, 1/3).identical(1 + CBF(0, 1)/3)
            True
            sage: CBF(1, 1).identical(1 + CBF(0, 1/3)*3)
            False
        """
        return acb_equal(self.value, other.value)

    def overlaps(self, ComplexBall other):
        """
        Return True iff ``self`` and ``other`` have some point in common.

        INPUT:

        - ``other`` -- a :class:`ComplexBall`.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(1, 1).overlaps(1 + CBF(0, 1/3)*3)
            True
            sage: CBF(1, 1).overlaps(CBF(1, 'nan'))
            True
            sage: CBF(1, 1).overlaps(CBF(0, 'nan'))
            False
        """
        return acb_overlaps(self.value, other.value)

    def contains_exact(self, other):
        """
        Return ``True`` *iff* ``other`` is contained in ``self``.

        INPUT:

        - ``other`` -- :class:`ComplexBall`,
          :class:`~sage.rings.integer.Integer`,
          or :class:`~sage.rings.rational.Rational`

        .. SEEALSO::

            Use ``other in self`` for a test that works for a wider range of
            inputs but may return false negatives.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: from sage.rings.real_arb import RealBallField
            sage: CBF(RealBallField(100)(1/3), 0).contains_exact(1/3)
            True
            sage: CBF(1).contains_exact(1)
            True
            sage: CBF(1).contains_exact(CBF(1))
            True
        """
        cdef fmpz_t tmpz
        cdef fmpq_t tmpq
        if _do_sig(prec(self)): sig_on()
        try:
            if isinstance(other, ComplexBall):
                res = acb_contains(self.value, (<ComplexBall> other).value)
            elif isinstance(other, sage.rings.integer.Integer):
                fmpz_init(tmpz)
                fmpz_set_mpz(tmpz, (<sage.rings.integer.Integer> other).value)
                res = acb_contains_fmpz(self.value, tmpz)
                fmpz_clear(tmpz)
            elif isinstance(other, sage.rings.rational.Rational):
                fmpq_init(tmpq)
                fmpq_set_mpq(tmpq, (<sage.rings.rational.Rational> other).value)
                res = acb_contains_fmpq(self.value, tmpq)
                fmpq_clear(tmpq)
            else:
                raise TypeError
        finally:
            if _do_sig(prec(self)): sig_off()
        return res

    def __contains__(self, other):
        """
        Return True if ``other`` can be verified to be contained in ``self``.

        Depending on the type of ``other``, the test may use interval
        arithmetic with a precision determined by the parent of ``self`` and
        may return false negatives.

        .. SEEALSO:: :meth:`contains_exact`

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: 1/3*i in CBF(0, 1/3)
            True

        A false negative::

            sage: from sage.rings.real_arb import RealBallField
            sage: RLF(1/3) in CBF(RealBallField(100)(1/3), 0)
            False
        """
        if not isinstance(other, (
                ComplexBall,
                sage.rings.integer.Integer,
                sage.rings.rational.Rational)):
            other = self._parent(other)
        return self.contains_exact(other)

    # Arithmetic

    def __neg__(self):
        """
        Return the opposite of this ball.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: -CBF(1/3 + I)
            [-0.3333333333333333 +/- 7.04e-17] - 1.000000000000000*I
        """
        cdef ComplexBall res = self._new()
        acb_neg(res.value, self.value)
        return res

    def conjugate(self):
        """
        Return the complex conjugate of this ball.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(-2 + I/3).conjugate()
            -2.000000000000000 + [-0.3333333333333333 +/- 7.04e-17]*I
        """
        cdef ComplexBall res = self._new()
        acb_conj(res.value, self.value)
        return res

    cpdef ModuleElement _add_(self, ModuleElement other):
        """
        Return the sum of two balls, rounded to the ambient field's precision.

        The resulting ball is guaranteed to contain the sums of any two points
        of the respective input balls.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(1) + CBF(I)
            1.000000000000000 + 1.000000000000000*I
        """
        cdef ComplexBall res = self._new()
        if _do_sig(prec(self)): sig_on()
        acb_add(res.value, self.value, (<ComplexBall> other).value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return res

    cpdef ModuleElement _sub_(self, ModuleElement other):
        """
        Return the difference of two balls, rounded to the ambient field's
        precision.

        The resulting ball is guaranteed to contain the differences of any two
        points of the respective input balls.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(1) - CBF(I)
            1.000000000000000 - 1.000000000000000*I
        """
        cdef ComplexBall res = self._new()
        if _do_sig(prec(self)): sig_on()
        acb_sub(res.value, self.value, (<ComplexBall> other).value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return res

    def __invert__(self):
        """
        Return the inverse of this ball.

        The result is guaranteed to contain the inverse of any point of the
        input ball.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: ~CBF(i/3)
            [-3.00000000000000 +/- 9.44e-16]*I
            sage: ~CBF(0)
            [+/- inf]
            sage: ~CBF(RIF(10,11))
            [0.1 +/- 9.53e-3]
        """
        cdef ComplexBall res = self._new()
        if _do_sig(prec(self)): sig_on()
        acb_inv(res.value, self.value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return res

    cpdef RingElement _mul_(self, RingElement other):
        """
        Return the product of two balls, rounded to the ambient field's
        precision.

        The resulting ball is guaranteed to contain the products of any two
        points of the respective input balls.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(-2, 1)*CBF(1, 1/3)
            [-2.333333333333333 +/- 5.37e-16] + [0.333333333333333 +/- 4.82e-16]*I
        """
        cdef ComplexBall res = self._new()
        if _do_sig(prec(self)): sig_on()
        acb_mul(res.value, self.value, (<ComplexBall> other).value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return res

    cpdef RingElement _div_(self, RingElement other):
        """
        Return the quotient of two balls, rounded to the ambient field's
        precision.

        The resulting ball is guaranteed to contain the quotients of any two
        points of the respective input balls.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: from sage.rings.real_arb import RBF
            sage: CBF(-2, 1)/CBF(1, 1/3)
            [-1.50000000000000 +/- 1.27e-15] + [1.500000000000000 +/- 8.94e-16]*I
            sage: CBF(2+I)/CBF(0)
            [+/- inf] + [+/- inf]*I
            sage: CBF(1)/CBF(0)
            [+/- inf]
            sage: CBF(1)/CBF(RBF(0, 1.))
            nan
        """
        cdef ComplexBall res = self._new()
        if _do_sig(prec(self)): sig_on()
        acb_div(res.value, self.value, (<ComplexBall> other).value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return res

    def __pow__(base, expo, _):
        """
        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: from sage.rings.real_arb import RBF
            sage: CBF(-1)**(1/2)
            [+/- 2.84e-16] + [1.00000000000000 +/- 4.45e-16]*I
            sage: CBF(e)**CBF(i*pi)
            [-1.0000000000000 +/- 1.98e-15] + [+/- 2.32e-15]*I
            sage: CBF(0, 1)**AA(2)**(1/2)
            [-0.60569986707881 +/- 4.36e-15] + [0.79569320156748 +/- 2.53e-15]*I

            sage: CBF(i)**RBF(2**1000)
            [+/- 2.51] + [+/- 2.87]*I
            sage: CBF(i)**(2**1000)
            1.000000000000000

            sage: CBF(0)^(1/3)
            nan + nan*I
            sage: CBF(0)^(-1)
            [+/- inf]
            sage: CBF(0)^(-2)
            [+/- inf] + [+/- inf]*I

        TESTS::

            sage: (CBF(e)**CBF(i))**RBF(pi)
            [-1.0000000000000 +/- 5.48e-15] + [+/- 4.14e-15]*I
            sage: CBF(2*i)**10r
            -1024.000000000000
        """
        cdef fmpz_t tmpz
        if not isinstance(base, ComplexBall):
            return sage.structure.element.bin_op(base, expo, operator.pow)
        cdef ComplexBall self = base
        cdef ComplexBall res = self._new()
        if isinstance(expo, int):
            if _do_sig(prec(self)): sig_on()
            acb_pow_ui(res.value, self.value, PyInt_AS_LONG(expo), prec(self))
            if _do_sig(prec(self)): sig_off()
        elif isinstance(expo, sage.rings.integer.Integer):
            if _do_sig(prec(self)): sig_on()
            fmpz_init(tmpz)
            fmpz_set_mpz(tmpz, (<sage.rings.integer.Integer> expo).value)
            acb_pow_fmpz(res.value, self.value, tmpz, prec(self))
            fmpz_clear(tmpz)
            if _do_sig(prec(self)): sig_off()
        elif isinstance(expo, ComplexBall):
            if _do_sig(prec(self)): sig_on()
            acb_pow(res.value, self.value, (<ComplexBall> expo).value, prec(self))
            if _do_sig(prec(self)): sig_off()
        elif isinstance(expo, RealBall):
            if _do_sig(prec(self)): sig_on()
            acb_pow_arb(res.value, self.value, (<RealBall> expo).value, prec(self))
            if _do_sig(prec(self)): sig_off()
        else:
            return sage.structure.element.bin_op(base, expo, operator.pow)
        return res

    def sqrt(self):
        """
        Return the square root of this ball.

        If either the real or imaginary part is exactly zero, only a single
        real square root is needed.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(-2).sqrt()
            [1.414213562373095 +/- 2.99e-16]*I
        """
        cdef ComplexBall res = self._new()
        if _do_sig(prec(self)): sig_on()
        acb_sqrt(res.value, self.value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return res

    def rsqrt(self):
        """
        Return the reciprocal square root of ``self``.

        If either the real or imaginary part is exactly zero, only a single
        real reciprocal square root is needed.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(-2).rsqrt()
            [-0.707106781186547 +/- 5.73e-16]*I
            sage: CBF(0, 1/2).rsqrt()
            1.000000000000000 - 1.000000000000000*I
            sage: CBF(0).rsqrt()
            nan
        """
        cdef ComplexBall res = self._new()
        if _do_sig(prec(self)): sig_on()
        acb_rsqrt(res.value, self.value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return res

    def cube(self):
        """
        Return the cube of this ball.

        The result is computed efficiently using two real squarings, two real
        multiplications, and scalar operations.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(1, 1).cube()
            -2.000000000000000 + 2.000000000000000*I
        """
        cdef ComplexBall res = self._new()
        if _do_sig(prec(self)): sig_on()
        acb_cube(res.value, self.value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return res

    def rising_factorial(self, n):
        """
        Return the ``n``-th rising factorial of this ball.

        The `n`-th rising factorial of `x` is equal to `x (x+1) \cdots (x+n-1)`.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(1).rising_factorial(5)
            120.0000000000000
            sage: CBF(1/3, 1/2).rising_factorial(300)
            [-3.87949484513701e+612 +/- 8.46e+597] + [-3.52042209762719e+612 +/- 7.70e+597]*I

            sage: CBF(1).rising_factorial(-1)
            Traceback (most recent call last):
            ...
            ValueError: expected a nonnegative index
            sage: CBF(1).rising_factorial(2**64)
            Traceback (most recent call last):
            ...
            OverflowError: index too large
        """
        cdef ComplexBall res = self._new()
        cdef sage.rings.integer.Integer n_as_Integer = ZZ.coerce(n)
        if mpz_fits_ulong_p(n_as_Integer.value):
            if _do_sig(prec(self)): sig_on()
            acb_rising_ui(res.value, self.value, mpz_get_ui(n_as_Integer.value), prec(self))
            if _do_sig(prec(self)): sig_off()
            return res
        elif n_as_Integer < 0:
            raise ValueError("expected a nonnegative index")
        else:
            raise OverflowError("index too large")

    # Elementary functions

    def log(self):
        """
        Return the principal branch of the natural logarithm of this ball.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(2*i).log()
            [0.6931471805599453 +/- 4.16e-17] + [1.570796326794897 +/- 6.65e-16]*I
            sage: CBF(-1).log()
            [3.141592653589793 +/- 5.61e-16]*I
            sage: CBF('inf').log()
            nan + nan*I
        """
        cdef ComplexBall res = self._new()
        if _do_sig(prec(self)): sig_on()
        acb_log(res.value, self.value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return res

    def log1p(self):
        """
        Return ``log(1 + self)``, computed accurately when ``self`` is close to
        zero.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: from sage.rings.real_arb import RBF
            sage: eps = RBF(1e-50)
            sage: CBF(1+eps, eps).log()
            [+/- 2.23e-16] + [1.000000000000000e-50 +/- 2.30e-66]*I
            sage: CBF(eps, eps).log1p()
            [1.000000000000000e-50 +/- 7.63e-68] + [1.00000000000000e-50 +/- 2.30e-66]*I
        """
        cdef ComplexBall res = self._new()
        if _do_sig(prec(self)): sig_on()
        acb_log1p(res.value, self.value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return res

    def exp(self):
        """
        Return the exponential of this ball.

        .. SEEALSO:: :meth:`exppii`

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(i*pi).exp()
            [-1.00000000000000 +/- 6.67e-16] + [+/- 5.68e-16]*I
        """
        cdef ComplexBall res = self._new()
        if _do_sig(prec(self)): sig_on()
        acb_exp(res.value, self.value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return res

    def exppii(self):
        """
        Return ``exp(pi*i*self)``.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(1/2).exppii()
            1.000000000000000*I
            sage: CBF(0, -1/pi).exppii()
            [2.71828182845904 +/- 6.05e-15]
        """
        cdef ComplexBall res = self._new()
        if _do_sig(prec(self)): sig_on()
        acb_exp_pi_i(res.value, self.value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return res

    def sin(self):
        """
        Return the sine of this ball.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(i*pi).sin()
            [11.5487393572577 +/- 5.34e-14]*I
        """
        cdef ComplexBall res = self._new()
        if _do_sig(prec(self)): sig_on()
        acb_sin(res.value, self.value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return res

    def cos(self):
        """
        Return the cosine of this ball.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(i*pi).cos()
            [11.59195327552152 +/- 8.38e-15]
        """
        cdef ComplexBall res = self._new()
        if _do_sig(prec(self)): sig_on()
        acb_cos(res.value, self.value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return res

    def tan(self):
        """
        Return the tangent of this ball.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(pi/2, 1/10).tan()
            [+/- 3.93e-14] + [10.033311132254 +/- 3.64e-13]*I
            sage: CBF(pi/2).tan()
            [+/- inf]
        """
        cdef ComplexBall res = self._new()
        if _do_sig(prec(self)): sig_on()
        acb_tan(res.value, self.value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return res

    def cot(self):
        """
        Return the cotangent of this ball.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(pi, 1/10).cot()
            [+/- 5.65e-14] + [-10.033311132254 +/- 4.75e-13]*I
            sage: CBF(pi).cot()
            [+/- inf]
        """
        cdef ComplexBall res = self._new()
        if _do_sig(prec(self)): sig_on()
        acb_cot(res.value, self.value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return res

    def arctan(self):
        """
        Return the arctangent of this ball.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(1+i).arctan()
            [1.017221967897851 +/- 4.93e-16] + [0.4023594781085251 +/- 8.52e-17]*I
            sage: CBF(i).arctan()
            nan + nan*I
        """
        cdef ComplexBall res = self._new()
        if _do_sig(prec(self)): sig_on()
        acb_atan(res.value, self.value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return res

    # Special functions

    def gamma(self, z=None):
        """
        Return the image of this ball by the Euler Gamma function (if
        ``z = None``) or the incomplete Gamma function (otherwise).

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(1, 1).gamma()
            [0.49801566811836 +/- 4.98e-15] + [-0.154949828301811 +/- 7.67e-16]*I
            sage: CBF(-1).gamma()
            nan
            sage: CBF(1, 1).gamma(0)
            [0.49801566811836 +/- 4.98e-15] + [-0.154949828301811 +/- 7.67e-16]*I
            sage: CBF(1, 1).gamma(100)
            [-3.6143867454139e-45 +/- 7.26e-59] + [-3.7022961377791e-44 +/- 4.71e-58]*I
            sage: CBF(1, 1).gamma(CLF(i))
            [0.32886684193500 +/- 5.49e-15] + [-0.18974945045621 +/- 1.49e-15]*I
        """
        cdef ComplexBall my_z
        cdef ComplexBall res = self._new()
        if z is None:
            if _do_sig(prec(self)): sig_on()
            acb_gamma(res.value, self.value, prec(self))
            if _do_sig(prec(self)): sig_off()
        else:
            my_z = self._parent.coerce(z)
            if _do_sig(prec(self)): sig_on()
            acb_hypgeom_gamma_upper(res.value, self.value, my_z.value, 0, prec(self))
            if _do_sig(prec(self)): sig_off()
        return res

    def log_gamma(self):
        r"""
        Return the image of this ball by the logarithmic Gamma function.

        The branch cut of the logarithmic gamma function is placed on the
        negative half-axis, which means that
        ``log_gamma(z) + log z = log_gamma(z+1)`` holds for all `z`,
        whereas ``log_gamma(z) != log(gamma(z))`` in general.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(1000, 1000).log_gamma()
            [5466.22252162990 +/- 3.05e-12] + [7039.33429191119 +/- 3.81e-12]*I
            sage: CBF(-1/2).log_gamma()
            [1.26551212348465 +/- 7.54e-15] + [-3.141592653589793 +/- 5.61e-16]*I
            sage: CBF(-1).log_gamma()
            nan + [-3.141592653589793 +/- 5.68e-16]*I
        """
        cdef ComplexBall res = self._new()
        if _do_sig(prec(self)): sig_on()
        acb_lgamma(res.value, self.value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return res

    def psi(self):
        """
        Compute the digamma function with argument ``self``.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(1, 1).psi()
            [0.0946503206224770 +/- 7.34e-17] + [1.076674047468581 +/- 2.63e-16]*I
            sage: CBF(-1).psi()
            nan
        """

        cdef ComplexBall result = self._new()
        if _do_sig(prec(self)): sig_on()
        acb_digamma(result.value, self.value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return result

    def zeta(self, a=None):
        """
        Return the image of this ball by the Hurwitz zeta function.

        For ``a = None``, this computes the Riemann zeta function.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(1, 1).zeta()
            [0.5821580597520036 +/- 5.27e-17] + [-0.9268485643308071 +/- 2.81e-17]*I
            sage: CBF(1, 1).zeta(1)
            [0.5821580597520036 +/- 5.27e-17] + [-0.9268485643308071 +/- 2.81e-17]*I
            sage: CBF(1, 1).zeta(1/2)
            [1.497919876084167 +/- 2.91e-16] + [0.2448655353684164 +/- 4.22e-17]*I
            sage: CBF(1, 1).zeta(CBF(1, 1))
            [-0.3593983122202835 +/- 3.01e-17] + [-2.875283329756940 +/- 4.52e-16]*I
            sage: CBF(1, 1).zeta(-1)
            nan + nan*I
        """
        cdef ComplexBall a_ball
        cdef ComplexBall res = self._new()
        if a is None:
            if _do_sig(prec(self)): sig_on()
            acb_zeta(res.value, self.value, prec(self))
            if _do_sig(prec(self)): sig_off()
        else:
            a_ball = self._parent.coerce(a)
            if _do_sig(prec(self)): sig_on()
            acb_hurwitz_zeta(res.value, self.value, a_ball.value, prec(self))
            if _do_sig(prec(self)): sig_off()
        return res

    def polylog(self, s):
        """
        Return the polylogarithm `\operatorname{Li}_s(\mathrm{self})`.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(2).polylog(1)
            [+/- 4.65e-15] + [-3.14159265358979 +/- 8.15e-15]*I
            sage: CBF(1, 1).polylog(CBF(1, 1))
            [0.3708160030469 +/- 2.38e-14] + [2.7238016577979 +/- 4.22e-14]*I

        TESTS::

            sage: CBF(2).polylog(1r)
            [+/- 4.65e-15] + [-3.14159265358979 +/- 8.15e-15]*I
        """
        cdef ComplexBall s_as_ball
        cdef sage.rings.integer.Integer s_as_Integer
        cdef ComplexBall res = self._new()
        try:
            s_as_Integer = ZZ.coerce(s)
            if mpz_fits_slong_p(s_as_Integer.value):
                if _do_sig(prec(self)): sig_on()
                acb_polylog_si(res.value, mpz_get_si(s_as_Integer.value), self.value, prec(self))
                if _do_sig(prec(self)): sig_off()
                return res
        except TypeError:
            pass
        s_as_ball = self._parent.coerce(s)
        if _do_sig(prec(self)): sig_on()
        acb_polylog(res.value, s_as_ball.value, self.value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return res

    def agm1(self):
        """
        Return the arithmetic-geometric mean of 1 and ``self``.

        The arithmetic-geometric mean is defined such that the function is
        continuous in the complex plane except for a branch cut along the
        negative half axis (where it is continuous from above). This
        corresponds to always choosing an "optimal" branch for the square root
        in the arithmetic-geometric mean iteration.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(0, -1).agm1()
            [0.5990701173678 +/- 1.14e-14] + [-0.5990701173678 +/- 1.22e-14]*I
        """
        cdef ComplexBall res = self._new()
        if _do_sig(prec(self)): sig_on()
        acb_agm1(res.value, self.value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return res

    def hypergeometric(self, a, b):
        r"""
        Return the generalized hypergeometric function of ``self``.

        INPUT:

        - ``a`` -- upper paramaters, list of complex numbers that coerce into
          this ball's parent;

        - ``b`` -- lower paramaters, list of complex numbers that coerce into
          this ball's parent.

        OUTPUT:

        The generalized hypergeometric function defined by

        .. math::

            {}_pF_q(a_1,\ldots,a_p;b_1,\ldots,b_q;z)
            = \sum_{k=0}^\infty \frac{(a_1)_k\dots(a_p)_k}{(b_1)_k\dots(b_q)_k} \frac {z^k} {k!}

        extended using analytic continuation or regularization when the sum
        does not converge.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(1, pi/2).hypergeometric([], [])
            [+/- 3.57e-15] + [2.7182818284590 +/- 5.37e-14]*I

            sage: CBF(0, 1).hypergeometric([], [1/2, 1/3, 1/4])
            [-3.7991962344383 +/- 4.98e-14] + [23.8780971778049 +/- 5.40e-14]*I

            sage: CBF(0).hypergeometric([1], [])
            1.000000000000000
            sage: CBF(1, 1).hypergeometric([1], [])
            [+/- inf] + [+/- inf]*I

        TESTS::

            sage: CBF(0, 1).hypergeometric([QQbar(sqrt(2)), RLF(pi)], [1r, 1/2])
            [-8.7029449215408 +/- 6.89e-14] + [-0.8499070546106 +/- 4.98e-14]*I
        """
        cdef ComplexBall tmp, res
        cdef long p = len(a)
        cdef long q = len(b)
        cdef acb_ptr my_a = _acb_vec_init(p)
        cdef acb_ptr my_b = _acb_vec_init(q + 1)
        for i in range(p):
            tmp = self._parent.coerce(a[i])
            acb_set(&(my_a[i]), tmp.value)
        for i in range(q):
            tmp = self._parent.coerce(b[i])
            acb_set(&(my_b[i]), tmp.value)
        acb_one(&(my_b[q]))
        res = self._new()
        if _do_sig(prec(self)): sig_on()
        acb_hypgeom_pfq_direct(res.value, my_a, p, my_b, q + 1,
                               self.value, -1, prec(self))
        if _do_sig(prec(self)): sig_off()
        _acb_vec_clear(my_b, q + 1)
        _acb_vec_clear(my_a, p)
        return res

    def hypergeometric_U(self, a, b):
        """
        Return the Tricomi confluent hypergeometric function U(a, b, self) of
        this ball.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(1000, 1000).hypergeometric_U(RLF(pi), -100)
            [-7.261605907166e-11 +/- 4.89e-24] + [-7.928136216391e-11 +/- 5.36e-24]*I
            sage: CBF(1000, 1000).hypergeometric_U(0, -100)
            1.000000000000000
        """
        cdef ComplexBall res = self._new()
        cdef ComplexBall my_a = self._parent.coerce(a)
        cdef ComplexBall my_b = self._parent.coerce(b)
        if _do_sig(prec(self)): sig_on()
        acb_hypgeom_u(res.value, my_a.value, my_b.value, self.value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return res

    def hypergeometric_M(self, a, b):
        """
        Return the Kummer confluent hypergeometric function M(a, b, self) of
        this ball.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(1, pi).hypergeometric_M(1/4, 1/4)
            [-2.7182818284590 +/- 8.63e-14] + [+/- 3.69e-14]*I
            sage: CBF(1000, 1000).hypergeometric_M(100, AA(sqrt(2)))
            [1.2796735556e+590 +/- 4.04e+579] + [-9.3233349199e+590 +/- 3.30e+579]*I
        """
        cdef ComplexBall res = self._new()
        cdef ComplexBall my_a = self._parent.coerce(a)
        cdef ComplexBall my_b = self._parent.coerce(b)
        if _do_sig(prec(self)): sig_on()
        acb_hypgeom_m(res.value, my_a.value, my_b.value, self.value, 0, prec(self))
        if _do_sig(prec(self)): sig_off()
        return res

    def erf(self):
        """
        Return the error function with argument ``self``.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(1, 1).erf()
            [1.31615128169795 +/- 8.80e-15] + [0.19045346923783 +/- 9.19e-15]*I
        """

        cdef ComplexBall result = self._new()
        if _do_sig(prec(self)): sig_on()
        acb_hypgeom_erf(result.value, self.value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return result

    def erfc(self):
        """
        Compute the complementary error function with argument ``self``.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(20).erfc()
            [5.3958656116079e-176 +/- 1.08e-190]
            sage: CBF(100, 100).erfc()
            [0.00065234366376858 +/- 6.52e-18] + [-0.00393572636292141 +/- 5.16e-18]*I
        """

        cdef ComplexBall result = self._new()
        if _do_sig(prec(self)): sig_on()
        acb_hypgeom_erfc(result.value, self.value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return result

    def bessel_J(self, nu):
        """
        Return the Bessel function of the first kind with argument ``self``
        and index ``nu``.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(1, 1).bessel_J(1)
            [0.614160334922903 +/- 8.48e-16] + [0.365028028827088 +/- 6.62e-16]*I
            sage: CBF(100, -100).bessel_J(1/3)
            [1.108431870251e+41 +/- 5.53e+28] + [-8.952577603125e+41 +/- 2.91e+28]*I
        """
        cdef ComplexBall result = self._new()
        cdef ComplexBall my_nu = self._parent.coerce(nu)
        if _do_sig(prec(self)): sig_on()
        acb_hypgeom_bessel_j(result.value, my_nu.value, self.value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return result

    def bessel_K(self, nu):
        """
        Return the modified Bessel function of the second kind with argument
        ``self`` and index ``nu``.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(1, 1).bessel_K(0)
            [0.08019772694652 +/- 3.19e-15] + [-0.35727745928533 +/- 1.08e-15]*I
            sage: CBF(1, 1).bessel_K(1)
            [0.02456830552374 +/- 6.22e-15] + [-0.45971947380119 +/- 6.74e-15]*I
            sage: CBF(100, 100).bessel_K(QQbar(i))
            [3.8693896656383e-45 +/- 2.43e-59] + [5.5071004234177e-46 +/- 7.41e-60]*I
        """
        cdef ComplexBall result = self._new()
        cdef ComplexBall my_nu = self._parent.coerce(nu)
        if _do_sig(prec(self)): sig_on()
        acb_hypgeom_bessel_k(result.value, my_nu.value, self.value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return result

    def exp_integral_e(self, s):
        """
        Return the image of this ball by the generalized exponential integral
        with index ``s``.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(1+i).exp_integral_e(1)
            [0.00028162445198 +/- 2.78e-15] + [-0.17932453503936 +/- 2.56e-15]*I
            sage: CBF(1+i).exp_integral_e(QQbar(i))
            [-0.10396361883964 +/- 4.92e-15] + [-0.16268401277783 +/- 4.78e-15]*I
        """
        cdef ComplexBall res = self._new()
        cdef ComplexBall my_s = self._parent.coerce(s)
        if _do_sig(prec(self)): sig_on()
        acb_hypgeom_expint(res.value, my_s.value, self.value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return res

    def ei(self):
        """
        Return the exponential integral with argument ``self``.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(1, 1).ei()
            [1.76462598556385 +/- 6.65e-15] + [2.38776985151052 +/- 4.34e-15]*I
            sage: CBF(0).ei()
            nan
        """
        cdef ComplexBall result = self._new()
        if _do_sig(prec(self)): sig_on()
        acb_hypgeom_ei(result.value, self.value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return result

    def si(self):
        """
        Return the sine integral with argument ``self``.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(1, 1).si()
            [1.10422265823558 +/- 2.16e-15] + [0.88245380500792 +/- 3.15e-15]*I
            sage: CBF(0).si()
            0
        """
        cdef ComplexBall result = self._new()
        if _do_sig(prec(self)): sig_on()
        acb_hypgeom_si(result.value, self.value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return result

    def ci(self):
        """
        Return the cosine integral with argument ``self``.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(1, 1).ci()
            [0.882172180555936 +/- 4.85e-16] + [0.287249133519956 +/- 3.47e-16]*I
            sage: CBF(0).ci()
            nan + nan*I
        """
        cdef ComplexBall result = self._new()
        if _do_sig(prec(self)): sig_on()
        acb_hypgeom_ci(result.value, self.value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return result

    def shi(self):
        """
        Return the hyperbolic sine integral with argument ``self``.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(1, 1).shi()
            [0.88245380500792 +/- 3.15e-15] + [1.10422265823558 +/- 2.16e-15]*I
            sage: CBF(0).shi()
            0
        """

        cdef ComplexBall result = self._new()
        if _do_sig(prec(self)): sig_on()
        acb_hypgeom_shi(result.value, self.value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return result

    def chi(self):
        """
        Return the hyperbolic cosine integral with argument ``self``.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(1, 1).chi()
            [0.882172180555936 +/- 4.85e-16] + [1.28354719327494 +/- 1.05e-15]*I
            sage: CBF(0).chi()
            nan + nan*I
        """
        cdef ComplexBall result = self._new()
        if _do_sig(prec(self)): sig_on()
        acb_hypgeom_chi(result.value, self.value, prec(self))
        if _do_sig(prec(self)): sig_off()
        return result

    def li(self, bint offset=False):
        """
        Return the logarithmic integral with argument ``self``.

        If ``offset`` is True, return the offset logarithmic integral.

        EXAMPLES::

            sage: from sage.rings.complex_ball_acb import CBF
            sage: CBF(1, 1).li()
            [0.61391166922119 +/- 7.03e-15] + [2.05958421419258 +/- 8.25e-15]*I
            sage: CBF(0).li()
            0
            sage: CBF(0).li(offset=True)
            [-1.045163780117493 +/- 5.54e-16]
            sage: li(0).n()
            0.000000000000000
            sage: Li(0).n()
            -1.04516378011749
        """
        cdef ComplexBall result = self._new()
        if _do_sig(prec(self)): sig_on()
        acb_hypgeom_li(result.value, self.value, offset, prec(self))
        if _do_sig(prec(self)): sig_off()
        return result

CBF = ComplexBallField()
