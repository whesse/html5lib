// TODO(jmesserly): remove this once we have a subclassable growable list
// in our libraries.

/** A [List] proxy that you can subclass. */
#library('list_proxy');

/**
 * A [List<T>] proxy that you can subclass.
 */
class ListProxy<T> implements List<T> {

  /** The inner [List<T>] with the actual storage. */
  final List<T> _list;

  /**
   * Creates a list proxy.
   * You can optionally specify the list to use for [storage] of the items,
   * otherwise this will create a [List<E>].
   */
  ListProxy([List<T> storage])
     : _list = storage != null ? storage : <T>[];

  // Implement every method from List ...
  Iterator<T> iterator() => _list.iterator();
  int get length() => _list.length;
  T operator [](int index) => _list[index];
  int indexOf(T element, [int start = 0]) => _list.indexOf(element, start);
  int lastIndexOf(T element, [int start]) => _list.lastIndexOf(element, start);
  List<T> getRange(int start, int length) => _list.getRange(start, length);
  void forEach(void f(T element)) => _list.forEach(f);
  Collection map(f(T element)) => _list.map(f);
  reduce(initialValue, combine(previousValue, T element)) =>
      _list.reduce(initialValue, combine);

  Collection<T> filter(bool f(T element)) => _list.filter(f);
  bool every(bool f(T element)) => _list.every(f);
  bool some(bool f(T element)) => _list.some(f);
  bool isEmpty() => _list.isEmpty();
  T last() => _list.last();

  set length(int value) { _list.length = value; }
  operator []=(int index, T value) { _list[index] = value; }
  void add(T value) { _list.add(value); }
  void addLast(T value) { _list.addLast(value); }
  void addAll(Collection<T> collection) { _list.addAll(collection); }
  void sort(int compare(T a, T b)) { _list.sort(compare); }
  void clear() { _list.clear(); }
  T removeLast() => _list.removeLast();
  void setRange(int start, int length, List<T> from, [int startFrom]) {
    _list.setRange(start, length, from, startFrom);
  }
  void removeRange(int start, int length) { _list.removeRange(start, length); }
  void insertRange(int start, int length, [T initialValue]) {
    _list.insertRange(start, length, initialValue);
  }
}
