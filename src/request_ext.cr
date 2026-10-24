# ActionDispatch::Request method predicates (Rails request.get?, .head?, …)
# reopened onto stdlib HTTP::Request — the port's request object IS the
# stdlib class, so the predicates land where controllers use them.

class HTTP::Request
  def get? : Bool
    method == "GET"
  end

  def head? : Bool
    method == "HEAD"
  end

  def post? : Bool
    method == "POST"
  end

  def patch? : Bool
    method == "PATCH"
  end

  def put? : Bool
    method == "PUT"
  end

  def delete? : Bool
    method == "DELETE"
  end
end
