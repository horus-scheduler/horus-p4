#!env python

#
# This class simulates Tofino Math unit. Please, see BEACON-201 or similar
# course for more details
#
# Usage:
#
#  # Calculating the square of the number
#  math_unit = MathUnit(shift=1, invert=False, scale=-6,
#                       lookup=[x*x for x in range(15, -1, -1)])
#
#  result = math_unit.compute(100)
#  # Hopefully this is close to 10000 :) Should be 9216, so 7.84% error
#
class MathUnit():
    #
    # Parameters (should be taken from your P4 program):
    #    shift  -- the same value  as the attribute math_unit_exponent_shift
    #    invert -- the same value  as the attribute math_unit_exponent_invert
    #    scale  -- the same value  as the attribute math_unit_output_scale
    #    lookup -- the same values as the attribute math_unit_lookup_table
    #    size   -- register width in bits (8, 16 or 32)
    
    def __init__(self, shift=0, invert=False, scale=-3,
                 lookup=range(15, -1, -1), size=32):
        if shift not in [-1, 0, 1]:
            raise ValueError("Shift can only be 0, 1 or -1")
        self.shift = shift

        if invert not in [True, False]:
            raise ValueError("Invert must be True of False")
        self.invert = invert

        self.scale  = scale

        if len(lookup) != 16:
            raise ValueError("lookup must have exactly 16 elements")
        for x in lookup:
            if not (0 <= x <= 255):
                raise ValueError("All lookup values must be between 0 and 255")
        self.lookup = lookup; self.lookup.reverse();

        if size not in [8, 16, 32]:
            raiseValueError("Size can only be 8, 16 or 32 (bits)")

        self.size = size
        self.mask = (1 << size) -1

    def compute(self, arg):
        if arg == 0:
            return 0

        # Get the exponent and mantissa
        arg1 = arg << 3               # Add 3 extra zeroes on the left
        exp1 = arg1.bit_length() - 1;

        # If we are going to calculate sqrt, we need an even exponent
        if self.shift == -1 and exp1 % 2 != 0:
            exp1 += 1

        exp  = exp1 - 3                # Compensate for the initial shift
        mantissa = (arg1 >> exp) & 0xF # First 4 bits

        # Calculate the new exponent

        # First let's do linear, square or square root
        if self.shift == -1:
            new_exp = exp >> 1
        elif self.shift == 0:
            new_exp = exp
        elif self.shift == 1:
            new_exp = exp << 1
        else:
            raise ValueError("Shift can only be 0, 1 or -1")

        # For the reciprocals the exponent is inverted
        if self.invert:
            new_exp = -new_exp

        # Finally, add the scale
        new_exp += self.scale
        
        new_mantissa = self.lookup[mantissa]
        if new_exp < 0:
            result = new_mantissa >> -new_exp
        else:
            result = new_mantissa << new_exp

        return result & self.mask
