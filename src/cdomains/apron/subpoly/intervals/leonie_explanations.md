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
    (TODO: handle cases)

# Case distinctions:
Case 1: x := 3z + 7y + 2 (the variable x is given a completely new value / x does not occur on the right side)
    -> do forget_var x, and then store this equation
    -> 0 = -x + 3z + 7y + 2 speichern (TODO: How?) -> don't introduce a slack variable, because its already a equality

Case 2: x := 5x + 7y + 6 (x is changed according to its previos value)
    -> do NOT forget_var, instead change all occurences of x according to this equation
    x_new = a*x_old + terms + c
    - a * x_old = - x_new + terms + c
    x_old = 1/a * x_new - (1/a) * terms - (1/a) * c
    -> substitute x by 1/a * x - (1/a) * terms - (1/a) * c
    call this function substitute_expr (different from substitute_exp)




