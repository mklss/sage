# sage.doctest: needs sage.combinat sage.modules
r"""
Abelian Lie Conformal Algebra

For a commutative ring `R` and a free `R`-module `M`. The *Abelian Lie
conformal algebra* generated by `M` is the free `R[T]` module
generated by `M` with vanishing `\lambda`-brackets.

AUTHORS:

- Reimundo Heluani (2020-06-15): Initial implementation.
"""

#******************************************************************************
#       Copyright (C) 2019 Reimundo Heluani <heluani@potuz.net>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#                  http://www.gnu.org/licenses/
#*****************************************************************************

from .graded_lie_conformal_algebra import GradedLieConformalAlgebra
from sage.structure.indexed_generators import standardize_names_index_set


class AbelianLieConformalAlgebra(GradedLieConformalAlgebra):
    r"""
    The Abelian Lie conformal algebra.

    INPUT:

    - ``R`` -- a commutative ring; the base ring of this Lie
      conformal algebra
    - ``ngens`` -- a positive integer (default: ``1``); the number
      of generators of this Lie conformal algebra
    - ``weights`` -- a list of positive rational numbers (default:
      ``1`` for each
      generator); the weights of the generators. The resulting
      Lie conformal algebra is `H`-graded.
    - ``parity`` -- ``None`` or a list of ``0`` or ``1`` (default:
      ``None``); The parity of the generators. If not ``None`` the
      resulting Lie Conformal algebra is a Super Lie conformal
      algebra
    - ``names`` -- a tuple of ``str`` or ``None`` (default: ``None``
      ); the list of names of the generators of this algebra.
    - ``index_set`` -- an enumerated set or ``None`` (default:
      ``None``); A set indexing the generators of this Lie
      conformal algebra.

    OUTPUT:

    The Abelian Lie conformal algebra with generators `a_i`,
    `i=1,...,n` and vanishing `\lambda`-brackets, where `n` is
    ``ngens``.

    EXAMPLES::

        sage: R = lie_conformal_algebras.Abelian(QQ,2); R
        The Abelian Lie conformal algebra with generators (a0, a1) over Rational Field
        sage: R.inject_variables()
        Defining a0, a1
        sage: a0.bracket(a1.T(2))
        {}

    TESTS::

        sage: R.central_elements()
        ()
        sage: R.structure_coefficients()
        Finite family {}

    .. TODO::

        implement its own class to speed up arithmetics in this
        case.
    """
    def __init__(self, R, ngens=1, weights=None,
                 parity=None, names=None, index_set=None):
        """
        Initialize self.

        EXAMPLES::

            sage: V = lie_conformal_algebras.Abelian(QQ)
            sage: TestSuite(V).run()
        """
        if (names is None) and (index_set is None):
            names = 'a'
            self._latex_names = tuple(r'a_{%d}' % i for i in range(ngens))

        names,index_set = standardize_names_index_set(names=names,
                                                      index_set=index_set,
                                                      ngens=ngens)
        abeliandict = {}

        GradedLieConformalAlgebra.__init__(self, R, abeliandict, names=names,
                                           index_set=index_set, weights=weights,
                                           parity=parity)

    def _repr_(self):
        """
        String representation.

        EXAMPLES::

            sage: lie_conformal_algebras.Abelian(QQ)
            The Abelian Lie conformal algebra with generators (a,) over Rational Field
        """
        return "The Abelian Lie conformal algebra with generators {} over {}"\
                .format(self.gens(), self.base_ring())
