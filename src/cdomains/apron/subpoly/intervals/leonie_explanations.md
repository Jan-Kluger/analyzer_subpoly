## ASSIGN
# simplified_monomials_from_texpr
returns 
- None: if we have something that is not a linear expression, we return None (e.g. if mod, x^2, xy,...)
- Some (terms, const): this represents a linear expression; const is the constant of type Z.t, terms is a list of pairs (a,x) where x is a variable and a ist the coefficient

This function already works with the indeces from the env (type int), and not with the varibale names.

example: env={x->0, y->1, z->2} and expression 4x + 7y + 3z +5 
    Some ([(4,0), (7,1), (3,2)], 5 )

# assign_exp and assign_texpr
assign_exp just converts the expression into type Texpr1, and then calls assign_texpr.

assign_texpr converts the variable name into the index and calls simplified_monomials_from_texpr. 
    Then it does case distinction, on the result of simplified_monomials_from_texpr. 

# Case distinctions:
Case 1: x := 3z + 7y + 2 (the variable x is given a completely new value / x does not occur on the right side)
    -> do forget_var x, and then store this equation
    -> 0 = -x + 3z + 7y + 2 speichern (TODO: How?) -> don't introduce a slack variable, because its already an equality
    Function: add_equation

Case 2: x := 5x + 7y + 6 (x is changed according to its previos value)
    -> do NOT forget_var, instead change all occurences of x according to this equation
    x_new = a*x_old + terms + c
    - a * x_old = - x_new + terms + c
    x_old = 1/a * x_new - (1/a) * terms - (1/a) * c
    -> substitute x by 1/a * x - (1/a) * terms - (1/a) * c
    Function: substitute_expr (different from substitute_exp) 
    TODO: what do we do with the interval?


# Case 1: add_equation
input: subpolyhedra t, and terms, c from simplified_monomials_from_texpr, and var (the variable which is shifted)
1. create the new row: constant in the last clumn, no new slack variable since we have equality
2. add this row to the affeq matrix


# Case 2: substitute_expr
input: subpolyhedra t, and terms, c from simplified_monomials_from_texpr, and var (the variable which is shifted)

IDEA: for the expression: x = a*x + terms + c (NOTE: here terms is already terms without a\*x)
      substitute x by 1/a * x + (-1/a) * (terms + c) in every affeq row which constains x

EXAMPLE:
    row: 1/2*x + 7y - slack = 0 with slack interavl [0,7]
    expr: x = 5x -3y + 5/3z + 1/3a + 11
    1. compute, what we have to substitute x by: substitute x by 1/5*x - 1/5* (-3y + 5/3z + 1/3a + 11) = 1/5*x +3/5y - 1/3z - 1/15a -11/5
    2. insert that into the row: 1/2*(1/5*x +3/5y - 1/3z - 1/15a -11/5) + 7y - slack = 0 with slack interavl [0,7]
        -> 1/10x +3/10y -1/6z -1/30a -11/10 +7y - slack = 1/10x +73/10y -1/6z -1/30a -11/10 - slack 

STRATEGY:
1. compute the expression var has to be subtituted by
2. fold over affeq. for every row do:
    - if var is not contained in the row: just add it to a new affeq
    - else (var is contained in the row): do the substitution
        1) multiply everything of substitute_x_by_this by the coeff of x, add the result to the roe and remove (coeff, x) from it 
        2) then fold over the row and att the coefficients of the same variables.






