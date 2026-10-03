def helper_a(x):
    return x + 1


def helper_b(x):
    return x * 2


def unrelated_function():
    return 0


class Box:
    def open(self):
        return helper_b(3)


def target(value):
    total = helper_a(value)
    total += helper_b(total)
    box = Box()
    return total + box.open()


def other():
    return unrelated_function()
